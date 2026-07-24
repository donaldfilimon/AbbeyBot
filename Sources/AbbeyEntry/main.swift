import AbbeyCLI
import AbbeyServer
import Foundation

#if ABBEY_HAS_DESKTOP
import AbbeyBotApp
#endif

/// Sole package `@main`. Bare `swift run` → desktop (macOS). Subcommands:
/// - `serve` / `server` → AbbeyServer (Vapor)
/// - `cli` / `abbey` / `repl` → abbey terminal REPL
@main
enum AbbeyEntry {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let program = CommandLine.arguments[0]
        let rest = Array(args.dropFirst())
        switch args.first?.lowercased() {
        case "serve", "server":
            // Normalize role → Vapor `serve` (+ remaining vapor flags).
            await AbbeyServerMain.main(arguments: [program, "serve"] + rest)
        case "cli", "abbey", "repl":
            do {
                try await AbbeyCLIMain.main(arguments: [program] + rest)
            } catch {
                fputs("abbey failed: \(error)\n", stderr)
                Foundation.exit(1)
            }
        case "help", "-h", "--help":
            print(Self.usage)
        case .none, "bot", "desktop", "app":
            await MainActor.run {
                Self.runDesktop()
            }
        default:
            fputs(
                """
                error: unknown command '\(args[0])'
                \(Self.usage)
                """,
                stderr
            )
            Foundation.exit(2)
        }
    }

    @MainActor
    private static func runDesktop() {
        #if ABBEY_HAS_DESKTOP
        AbbeyDesktopMain.main()
        #else
        fputs(
            """
            error: desktop UI requires the full package graph (no ABBEY_PACKAGE_ROLE=server).
            Use: swift run AbbeyBot serve
                 swift run AbbeyBot cli
            """,
            stderr
        )
        Foundation.exit(2)
        #endif
    }

    private static var usage: String {
        """
        AbbeyBot — unified entry (bare `swift run` defaults to desktop on macOS)

          swift run                              desktop companion
          swift run AbbeyBot serve [vapor args]  AbbeyServer HTTP + Discord
          swift run AbbeyBot cli                 abbey terminal REPL
          swift run AbbeyBot help

        Wrappers: Scripts/run.sh | run-server.sh | run-abbey.sh
        Server-only graph (Linux/Docker/swiftly): ABBEY_PACKAGE_ROLE=server
        """
    }
}
