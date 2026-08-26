import Foundation
import Vapor

public enum AbbeyServerMode: Sendable {
    case full
    case quasarOnly(allowsTokenlessLoopback: Bool)
}

/// HTTP + Discord server entry (invoked as `swift run -- serve`).
public enum AbbeyServerMain {
    public static func main(
        arguments: [String] = CommandLine.arguments,
        mode: AbbeyServerMode = .full
    ) async {
        do {
            var env = try Environment.detect(arguments: arguments)
            try LoggingSystem.bootstrap(from: &env)
            let app = try await Application.make(env)
            do {
                switch mode {
                case .full:
                    try await configure(app)
                case .quasarOnly(let allowsTokenlessLoopback):
                    try await configureQuasarOnly(
                        app,
                        allowsTokenlessLoopback: allowsTokenlessLoopback
                    )
                }
                try await app.execute()
                try await app.asyncShutdown()
            } catch {
                app.logger.report(error: error)
                try? await app.asyncShutdown()
                // Prefer a clean exit over `swift_errorInMain` (SIGTRAP / "Fatal error")
                // when configure/boot fails (e.g. bad DATABASE_URL or unreachable Postgres).
                Foundation.exit(1)
            }
        } catch {
            // Environment / Application.make failed before we had a logger.
            // `FileHandle.standardError`, not `fputs(..., stderr)`: on Linux
            // Glibc exposes `stderr` as a mutable global, which Swift 6 strict
            // concurrency rejects as shared mutable state.
            FileHandle.standardError.write(
                Data("AbbeyServer failed to start: \(error)\n".utf8)
            )
            Foundation.exit(1)
        }
    }
}
