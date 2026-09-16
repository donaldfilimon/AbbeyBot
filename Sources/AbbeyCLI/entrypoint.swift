import AbbeyCore
import AbbeyServerKit
import Foundation
import Vapor

/// Terminal REPL entry (invoked as `swift run AbbeyBot cli`).
public enum AbbeyCLIMain {
    public static func main(arguments: [String] = CommandLine.arguments) async throws {
        var env = try Environment.detect(arguments: arguments)
        try LoggingSystem.bootstrap(from: &env)

        // The sqlite driver will not create this directory for us — do it before Fluent
        // tries to open a file inside it. Let failures propagate as a clear startup error.
        let dir = try AbbeyDataDirectory.ensure().path
        let defaultDatabaseURL = "sqlite://\(dir)/abbey.sqlite"

        let app = try await Application.make(env)
        var didStart = false
        do {
            let runtime = try await configureRuntime(app, defaultDatabaseURL: defaultDatabaseURL)
            // No app.lifecycle.use(...) here — that's AbbeyServer's job for the HTTP
            // process. We drive start()/stop() directly so the runtime is never stopped
            // twice from two different triggers.
            await runtime.start()
            didStart = true

            print("""
            Abbey CLI — chatting with the Abbey persona locally (no Discord connection required).
            Type /help for commands, or just start chatting.
            """)

            await ConversationLoop(runtime: runtime).run()

            await runtime.stop()
            try await app.asyncShutdown()
        } catch {
            app.logger.report(error: error)
            let detail = OperatorFacingError.message(error)
            let prefix = didStart ? "abbey exited with error" : "abbey failed to start"
            FileHandle.standardError.write(Data("\(prefix): \(detail)\n".utf8))
            try? await app.asyncShutdown()
            Foundation.exit(1)
        }
    }
}
