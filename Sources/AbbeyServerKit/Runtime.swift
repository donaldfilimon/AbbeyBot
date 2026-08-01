import AbbeyCore
import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import Vapor

/// Selects the Fluent driver from `DATABASE_URL` (falling back to `defaultDatabaseURL`),
/// runs migrations, and constructs the shared `BotRuntime`. Does **not** register
/// `app.lifecycle` — callers decide how to start/stop the runtime (Vapor lifecycle for
/// `AbbeyServer`, direct `start()`/`stop()` calls for `AbbeyCLI`) so a runtime never gets
/// stopped twice from two different triggers.
///
/// Callers that want a local sqlite fallback when Postgres is down must set
/// `DATABASE_URL` explicitly (see `Scripts/run-server.sh`); this function does not probe
/// the network or silently change database identity.
public func configureRuntime(_ app: Application, defaultDatabaseURL: String) async throws -> BotRuntime {
    try AppConfig.shared.validateForStartup(scope: .headless)

    let databaseURL = Environment.get("DATABASE_URL").flatMap { $0.isEmpty ? nil : $0 }
        ?? defaultDatabaseURL

    let dialect: String
    if databaseURL.hasPrefix("postgres://") || databaseURL.hasPrefix("postgresql://") {
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
        app.databases.default(to: .psql)
        dialect = "postgres"
    } else if databaseURL == "sqlite://memory" || databaseURL == "sqlite::memory:" {
        // Unique id per Application so kit tests that each call configureRuntime do not
        // silently share one process-wide in-memory database under the shared `.sqlite` id.
        let id = DatabaseID(string: "sqlite-memory-\(UUID().uuidString)")
        app.databases.use(.sqlite(.memory), as: id)
        app.databases.default(to: id)
        dialect = "sqlite-memory"
    } else if databaseURL.hasPrefix("sqlite://") {
        let path = String(databaseURL.dropFirst("sqlite://".count))
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty, parent != "." {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
        // Path-derived id isolates temp-file test DBs; the live server still has one Application.
        let id = DatabaseID(string: "sqlite-file-\(path.hashValue)")
        app.databases.use(.sqlite(.file(path)), as: id)
        app.databases.default(to: id)
        dialect = "sqlite-file"
    } else {
        throw Abort(
            .internalServerError,
            reason: "DATABASE_URL must be postgres://… or sqlite://… (sqlite://memory for in-memory smoke)"
        )
    }
    app.databaseDialect = dialect
    app.logger.info("Database dialect: \(dialect)")

    app.migrations.add(CreateAll())
    app.migrations.add(AddSyncSourceTimestamps())
    try await app.autoMigrate()

    let runtime = BotRuntime(app: app)
    app.botRuntime = runtime
    return runtime
}

public struct BotLifecycleHandler: LifecycleHandler {
    public init() {}

    public func didBootAsync(_ app: Application) async throws {
        await app.botRuntime.start()
        // Env-gated, off by default; logs and skips on any missing config or Helix failure.
        await TwitchEventSubAutoSubscriber.subscribeIfConfigured(app: app)
    }

    public func shutdownAsync(_ app: Application) async {
        await app.botRuntime.stop()
    }
}

extension Application {
    private struct DatabaseDialectKey: StorageKey {
        typealias Value = String
    }

    public var databaseDialect: String {
        get { storage[DatabaseDialectKey.self] ?? "unknown" }
        set { storage[DatabaseDialectKey.self] = newValue }
    }
}
