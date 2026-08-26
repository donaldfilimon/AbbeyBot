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
        case "quasar":
            let quasarArgs = rest.first?.lowercased() == "serve" ? Array(rest.dropFirst()) : rest
            do {
                let configuration = try QuasarServePolicy.prepare(arguments: quasarArgs)
                await AbbeyServerMain.main(
                    arguments: [program, "serve"] + configuration.vaporArguments,
                    mode: .quasarOnly(
                        allowsTokenlessLoopback: configuration.allowsTokenlessLoopback
                    )
                )
            } catch {
                Self.writeStandardError("error: \(error.localizedDescription)\n")
                Foundation.exit(2)
            }
        case "cli", "abbey", "repl":
            do {
                try await AbbeyCLIMain.main(arguments: [program] + rest)
            } catch {
                Self.writeStandardError("abbey failed: \(error)\n")
                Foundation.exit(1)
            }
        case "help", "-h", "--help":
            print(Self.usage)
        case .none, "bot", "desktop", "app":
            await MainActor.run {
                Self.runDesktop()
            }
        default:
            Self.writeStandardError(
                """
                error: unknown command '\(args[0])'
                \(Self.usage)
                """
            )
            Foundation.exit(2)
        }
    }

    @MainActor
    private static func runDesktop() {
        #if ABBEY_HAS_DESKTOP
        AbbeyDesktopMain.main()
        #else
        Self.writeStandardError(
            """
            error: desktop UI requires the full package graph (no ABBEY_PACKAGE_ROLE=server).
            Use: swift run AbbeyBot serve
                 swift run AbbeyBot cli
            """
        )
        Foundation.exit(2)
        #endif
    }

    /// Write to stderr without touching the C `stderr` global.
    ///
    /// Glibc declares `extern FILE *stderr;` — a *mutable* global, which Swift 6 strict
    /// concurrency rejects ("reference to var 'stderr' is not concurrency-safe"). musl
    /// declares `extern FILE *const stderr;`, so the same code compiles under the static
    /// Linux (musl) SDK and only fails on the glibc/bookworm image CI uses. Route through
    /// `FileHandle.standardError` instead, matching `AbbeyServerMain`.
    private static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static var usage: String {
        """
        AbbeyBot — unified entry (bare `swift run` defaults to desktop on macOS)

          swift run                              desktop companion
          swift run AbbeyBot serve [vapor args]  AbbeyServer HTTP + Discord
          swift run AbbeyBot cli                 abbey terminal REPL
          swift run AbbeyBot quasar serve        loopback Quasar API on port 4700
          swift run AbbeyBot help

        Wrappers: Scripts/swift-run.sh (TMPDIR build path) | run.sh | run-server.sh | run-abbey.sh
        Prefer: bash Scripts/swift-run.sh help   # same as Xcode swift run + --build-path $TMPDIR
        Server-only graph (Linux/Docker/swiftly): ABBEY_PACKAGE_ROLE=server
        """
    }
}
