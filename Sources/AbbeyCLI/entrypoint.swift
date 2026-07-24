import AbbeyServerKit
import Foundation
import Vapor

@main
enum AbbeyCLIMain {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.abbey"
        // The sqlite driver will not create this directory for us — do it before Fluent
        // tries to open a file inside it. Let failures propagate as a clear startup error.
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let defaultDatabaseURL = "sqlite://\(dir)/abbey.sqlite"

        let app = try await Application.make(env)
        do {
            let runtime = try await configureRuntime(app, defaultDatabaseURL: defaultDatabaseURL)
            // No app.lifecycle.use(...) here — that's AbbeyServer's job for the HTTP
            // process. We drive start()/stop() directly so the runtime is never stopped
            // twice from two different triggers.
            await runtime.start()

            print("""
            Abbey CLI — chatting with the Abbey persona locally (no Discord connection required).
            Type /help for commands, or just start chatting.
            """)

            await ConversationLoop(runtime: runtime).run()

            await runtime.stop()
            try await app.asyncShutdown()
        } catch {
            app.logger.report(error: error)
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("abbey failed to start: \(detail)\n".utf8))
            try? await app.asyncShutdown()
            Foundation.exit(1)
        }
    }
}
