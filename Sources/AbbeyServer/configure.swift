import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import Leaf
import Vapor

public func configure(_ app: Application) async throws {
    let viewsPath = Bundle.module.bundleURL
        .appendingPathComponent("Resources")
        .appendingPathComponent("Views")
        .path
    app.directory.viewsDirectory = viewsPath.hasSuffix("/") ? viewsPath : viewsPath + "/"
    app.views.use(.leaf)

    let databaseURL = Environment.get("DATABASE_URL")
        ?? "postgres://abbey:abbey@localhost:5432/abbeybot"

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

    app.lifecycle.use(BotLifecycleHandler())

    try routes(app)
}

struct BotLifecycleHandler: LifecycleHandler {
    func didBoot(_ app: Application) throws {
        let runtime = app.botRuntime
        Task {
            await runtime.start()
        }
    }

    func shutdown(_ app: Application) {
        let runtime = app.botRuntime
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await runtime.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }
}

extension Application {
    private struct DatabaseDialectKey: StorageKey {
        typealias Value = String
    }

    var databaseDialect: String {
        get { storage[DatabaseDialectKey.self] ?? "unknown" }
        set { storage[DatabaseDialectKey.self] = newValue }
    }
}
