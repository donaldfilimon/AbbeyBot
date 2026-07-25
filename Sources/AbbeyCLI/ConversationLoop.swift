import AbbeyCore
import AbbeyServerKit
import Foundation

/// The interactive REPL core for the Abbey CLI. Reads lines from stdin, classifies them
/// with `CLICommandParser`, and drives a `BotRuntime` directly — no HTTP layer, no Vapor
/// lifecycle involved (the caller owns `runtime.start()`/`runtime.stop()`).
final class ConversationLoop {
    let runtime: BotRuntime
    private var sessionIndex = 0

    /// Pseudo IDs standing in for what would normally come from Discord. `channelId` is
    /// recomputed from `sessionIndex` each turn, so `/clear` bumping the index starts a
    /// fresh channel context for the persona/memory layer — non-destructive, the old
    /// session's rows remain in the DB, nothing gets deleted.
    private var currentChannelId: String {
        "cli-\(sessionIndex)"
    }

    init(runtime: BotRuntime) {
        self.runtime = runtime
    }

    func run() async {
        // Background listener: surfaces live, Discord-driven events (persona switches,
        // inference-provider fallbacks) in the terminal even while the human is mid-typing
        // at the prompt. Kept simple — no attempt to interleave cleanly with the prompt line.
        let eventTask = Task { [runtime] in
            for await event in await runtime.eventBus.subscribe() {
                switch event {
                case .inferenceProviderFailed(_, let message):
                    print("\n[provider fallback: \(message)]")
                case .personaSwitched(let name):
                    print("\n[persona switched to \(name)]")
                default:
                    break
                }
            }
        }
        defer { eventTask.cancel() }

        replLoop: while true {
            print("abbey> ", terminator: "")
            guard let line = readLine() else {
                // EOF (e.g. Ctrl-D) — exit cleanly.
                break replLoop
            }

            switch CLICommandParser.parse(line) {
            case .help:
                printHelp()

            case .clear:
                sessionIndex += 1
                // Nice-to-have: clear the terminal so the new session starts on a blank
                // screen. Not load-bearing — the divider message below is the real signal.
                print("\u{1B}[2J\u{1B}[H", terminator: "")
                print("Started a new conversation.")

            case .model(nil):
                let current = AppConfig.shared.inferenceMode
                let valid = InferenceMode.allCases.map(\.rawValue).joined(separator: ", ")
                print("Current inference mode: \(current.rawValue)")
                print("Valid values: \(valid)")

            case .model(let name?):
                if let mode = InferenceMode(rawValue: name) {
                    AppConfig.shared.inferenceMode = mode
                    print("Inference mode set to \(mode.rawValue).")
                } else {
                    let valid = InferenceMode.allCases.map(\.rawValue).joined(separator: ", ")
                    print("Unknown inference mode '\(name)'. Valid values: \(valid)")
                }

            case .validate(let source):
                let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    print("Usage: /validate <source code snippet>")
                    print("(Static CodeProposalValidator only — not a sandbox.)")
                    continue
                }
                switch CodeProposalValidator.validate(trimmed) {
                case .accepted:
                    print("accepted (static gate only — not a sandbox)")
                case .rejected(let reasons):
                    print("rejected:")
                    for reason in reasons {
                        print("  - \(reason)")
                    }
                }

            case .sync(nil):
                let snapshot = await runtime.syncStatusSnapshot()
                let shared = CLISyncStatusReport.sharesServerDatabase(
                    environment: ProcessInfo.processInfo.environment
                )
                print(CLISyncStatusReport.render(snapshot, sharesServerDatabase: shared))

            case .sync("pull"):
                for line in await CLISyncPull.run(runtime: runtime) {
                    print(line)
                }

            case .sync("push"):
                for line in await CLISyncPush.run(runtime: runtime) {
                    print(line)
                }

            case .sync(let argument?):
                print("Unknown /sync argument '\(argument)'. Usage: /sync (status), /sync pull, or /sync push.")

            case .exit:
                break replLoop

            case .chat(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                await handleChat(trimmed)
            }
        }
    }

    private func printHelp() {
        print("""
        Commands:
          /help            Show this help text.
          /clear           Start a new conversation (fresh channel context).
          /model [mode]    Show or set the inference mode (\(InferenceMode.allCases.map(\.rawValue).joined(separator: ", "))).
          /validate <src>  Static CodeProposalValidator (not a sandbox).
          /sync            Show the desktop-reported sync status in this database (read-only).
          /sync pull       Pull server rows into this database (ABBEY_SYNC_SERVER_URL; cursor at ~/.abbey/cli-sync-cursor).
          /sync push       Push local messages + memory facts to the server (cursor at ~/.abbey/cli-sync-push-cursor).
          /exit, /quit     Quit.
        """)
    }

    private func handleChat(_ text: String) async {
        let channelId = currentChannelId
        await runtime.ingestMessage(
            content: text,
            channelId: channelId,
            guildId: "cli",
            authorId: "local",
            discordMessageId: UUID().uuidString
        )
        let reply = await runtime.reply(to: text, userId: "local", guildId: "cli", channelId: channelId)
        await printStreamed(reply)
    }

    /// Simulated "typewriter" streaming: the full reply is already in hand (no
    /// `InferenceProvider` in this codebase streams tokens today) — this just prints it in
    /// small chunks with a short delay between them for a nicer terminal feel.
    private func printStreamed(_ text: String) async {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        guard !words.isEmpty else {
            print()
            return
        }
        for (index, word) in words.enumerated() {
            print(word, terminator: index == words.count - 1 ? "" : " ")
            try? await Task.sleep(for: .milliseconds(15))
        }
        print()
    }
}
