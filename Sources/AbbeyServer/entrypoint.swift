import Foundation
import Vapor

@main
enum AbbeyServerMain {
    static func main() async {
        do {
            var env = try Environment.detect()
            try LoggingSystem.bootstrap(from: &env)
            let app = try await Application.make(env)
            do {
                try await configure(app)
                try await app.execute()
                try await app.asyncShutdown()
            } catch {
                app.logger.report(error: error)
                try? await app.asyncShutdown()
                // Prefer a clean exit over `swift_errorInMain` (SIGTRAP / "Fatal error"),
                // which macOS records as a crash when Postgres is down and DATABASE_URL is unset.
                Foundation.exit(1)
            }
        } catch {
            // Environment / Application.make failed before we had a logger.
            fputs("AbbeyServer failed to start: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
