import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import Vapor
#if canImport(Network)
import Network
#endif

/// Selects the Fluent driver from `DATABASE_URL` (falling back to `defaultDatabaseURL`),
/// runs migrations, and constructs the shared `BotRuntime`. Does **not** register
/// `app.lifecycle` — callers decide how to start/stop the runtime (Vapor lifecycle for
/// `AbbeyServer`, direct `start()`/`stop()` calls for `AbbeyCLI`) so a runtime never gets
/// stopped twice from two different triggers.
///
/// When `DATABASE_URL` is unset and the default is Postgres but nothing is listening on
/// that host/port, falls back to a sqlite file under the process temp directory so local
/// `run-server.sh` / `swift run AbbeyServer` does not trap with `swift_errorInMain`.
public func configureRuntime(_ app: Application, defaultDatabaseURL: String) async throws -> BotRuntime {
    let databaseURL = resolveDatabaseURL(default: defaultDatabaseURL, logger: app.logger)

    let dialect: String
    if databaseURL.hasPrefix("postgres://") || databaseURL.hasPrefix("postgresql://") {
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
        dialect = "postgres"
    } else if databaseURL == "sqlite://memory" || databaseURL == "sqlite::memory:" {
        app.databases.use(.sqlite(.memory), as: .sqlite)
        dialect = "sqlite-memory"
    } else if databaseURL.hasPrefix("sqlite://") {
        let path = String(databaseURL.dropFirst("sqlite://".count))
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty, parent != "." {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
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

/// Prefer an explicit `DATABASE_URL`. Otherwise, if the default is Postgres and that
/// endpoint is not accepting TCP connections, use a temp sqlite file instead of failing boot.
func resolveDatabaseURL(default defaultDatabaseURL: String, logger: Logger) -> String {
    if let explicit = Environment.get("DATABASE_URL"), !explicit.isEmpty {
        return explicit
    }
    if defaultDatabaseURL.hasPrefix("postgres://") || defaultDatabaseURL.hasPrefix("postgresql://"),
       let endpoint = postgresTCPEndpoint(from: defaultDatabaseURL),
       !tcpEndpointReachable(host: endpoint.host, port: endpoint.port, timeout: 0.4)
    {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-server.sqlite")
            .path
        logger.warning(
            "DATABASE_URL unset and Postgres at \(endpoint.host):\(endpoint.port) unreachable; using sqlite://\(path)"
        )
        return "sqlite://\(path)"
    }
    return defaultDatabaseURL
}

func postgresTCPEndpoint(from urlString: String) -> (host: String, port: UInt16)? {
    guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return nil }
    let port = UInt16(url.port ?? 5432)
    return (host, port)
}

func tcpEndpointReachable(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
#if canImport(Network)
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
    final class ProbeState: @unchecked Sendable {
        var reachable = false
        let lock = NSLock()
        func markReady() {
            lock.lock()
            reachable = true
            lock.unlock()
        }
        var isReady: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reachable
        }
    }
    let state = ProbeState()
    let semaphore = DispatchSemaphore(value: 0)
    let connection = NWConnection(
        host: NWEndpoint.Host(host),
        port: nwPort,
        using: .tcp
    )
    connection.stateUpdateHandler = { connectionState in
        switch connectionState {
        case .ready:
            state.markReady()
            connection.cancel()
            semaphore.signal()
        case .failed, .cancelled:
            semaphore.signal()
        default:
            break
        }
    }
    connection.start(queue: DispatchQueue(label: "abbey.postgres.probe"))
    _ = semaphore.wait(timeout: .now() + timeout)
    connection.cancel()
    return state.isReady
#else
    // Linux CI/Docker always sets DATABASE_URL explicitly; without Network.framework
    // treat an unset URL + postgres default as unreachable so boot uses sqlite.
    _ = host
    _ = port
    _ = timeout
    return false
#endif
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
