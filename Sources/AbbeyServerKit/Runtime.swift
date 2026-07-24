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
public func configureRuntime(_ app: Application, defaultDatabaseURL: String) async throws -> BotRuntime {
    let databaseURL = Environment.get("DATABASE_URL") ?? defaultDatabaseURL

    let dialect: String
    if databaseURL.hasPrefix("postgres://") || databaseURL.hasPrefix("postgresql://") {
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
        dialect = "postgres"
    } else if databaseURL == "sqlite://memory" || databaseURL == "sqlite::memory:" {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        dialect = "sqlite-memory"
    } else if databaseURL.hasPrefix("sqlite://") {
        let path = String(databaseURL.dropFirst("sqlite://".count))
        app.databases.use(.sqlite(.file(path)), as: .sqlite)
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
    try await app.autoMigrate()

    let runtime = BotRuntime(app: app)
    app.botRuntime = runtime
    return runtime
}

public struct BotLifecycleHandler: LifecycleHandler {
    public init() {}

    public func didBootAsync(_ app: Application) async throws {
        await app.botRuntime.start()
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
