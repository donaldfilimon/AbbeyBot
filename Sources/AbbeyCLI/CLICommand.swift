import Foundation

/// A parsed line of user input from the Abbey CLI REPL.
enum CLICommand: Equatable {
    case help
    case clear
    case model(String?)
    case validate(String)
    case sync
    case exit
    case chat(String)
}

/// Parses raw REPL input into a `CLICommand`. Pure — no I/O — so it is directly
/// unit-testable without a running `BotRuntime`.
///
/// Conventions:
/// - Leading/trailing whitespace is trimmed before classification.
/// - An empty (or whitespace-only) line parses to `.chat("")`. The parser does not treat
///   blank input specially; the REPL loop is responsible for skipping empty chat text so a
///   bare Enter press doesn't trigger an ingest/reply round-trip.
/// - `/help`, `/clear`, `/exit`, `/quit`, `/sync` map to their fixed commands (case-insensitive);
///   `/sync` ignores any trailing argument since it only reads status.
/// - `/model` with no argument maps to `.model(nil)`; `/model <arg>` maps to
///   `.model("<arg>")` with the argument trimmed.
/// - An unrecognized `/something` command falls back to `.chat(<trimmed original line>)`
///   rather than being silently swallowed as a no-op — the caller can decide how to react
///   (e.g. route it to the assistant, which will typically just not understand it, or print
///   an explicit "unrecognized command" message before falling through).
enum CLICommandParser {
    static func parse(_ line: String) -> CLICommand {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("/") else {
            return .chat(trimmed)
        }

        let body = trimmed.dropFirst()
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let keyword = (parts.first.map(String.init) ?? "").lowercased()
        let argument: String? = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        switch keyword {
        case "help":
            return .help
        case "clear":
            return .clear
        case "exit", "quit":
            return .exit
        case "model":
            if let argument, !argument.isEmpty {
                return .model(argument)
            }
            return .model(nil)
        case "validate":
            return .validate(argument ?? "")
        case "sync":
            return .sync
        default:
            return .chat(trimmed)
        }
    }
}
