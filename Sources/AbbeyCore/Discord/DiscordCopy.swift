import Foundation

/// User-facing Discord / slash-command copy shared by Desktop and AbbeyServer.
public enum DiscordCopy: Sendable {
    public static let engineUnavailable = "Engine unavailable."
    public static let noMemory = "No memory for that user."
    public static let invalidFactIndex = "Invalid fact index."
    public static let noChannelSummary = "No channel summary yet."
    public static let notAuthorized =
        "You are not authorized for that operation. Self-memory commands are self-scoped; global settings require an operator or Discord administrator."

    /// Voice presence MVP — never claim audio capture or playback.
    public static let voiceNotConnected = "Not connected to Discord — connect before joining voice."
    public static let voiceMissingGuild = "Need a server (guild) id to join or leave voice."
    public static let voiceMissingChannel = "Need a voice channel id to join."
    public static let voiceLeaveFailed = "Could not leave voice — gateway not ready (presence only — no audio)."
    public static let voiceDryRunNoGateway =
        "Dry-run mode — Discord gateway is not active; voice presence unavailable (connect live for presence only — no audio)."
    public static let voiceUnknownSubcommand = "Use `/voice join` or `/voice leave` (presence only — no audio)."
    public static let voicePresenceOnly = "Presence only — muted & deafened; no audio (DiscordBM has no Opus/UDP)."
    /// Shown when the operator asks to start receiving and the session cannot.
    /// Deliberately says what is and is not true rather than "failed": receive
    /// needs a composed media stack and an established session, and neither is
    /// a user error.
    public static let voiceReceiveUnavailable =
        "Cannot receive audio: this session has no composed playback path, or it is not established yet."

    public static let voiceMuteDeafenNotConfirmed =
        "Not confirmed in a voice channel yet — mute/deafen presence can't be changed until Discord confirms the join."
    public static let voiceMuteDeafenGatewayUnavailable =
        "Not connected to Discord — connect before changing mute/deafen presence."

    public static let equityDisabled =
        "Equity module is disabled (`ABBEY_EQUITY_MODULE` / Settings). Synthetic screen only — not financial advice."
    public static let equityBadSymbol = "Pass a short ticker-like symbol (letters/numbers, max 12)."
    public static let equityDisclaimer =
        "Not financial advice. Scores are synthetic factor screens, not market data."

    public static let modelUnknown =
        "Unknown mode. Use: `ondevice` | `remote` | `floor` (or omit to show current)."
    public static let emptyTopic = "Provide a non-empty topic or question."
    public static let emptySituation = "Describe the moderation situation to get advice (advice only — no actions)."

    public static func reputation(userId: String, value: Double) -> String {
        "Reputation for \(userId): \(String(format: "%.3f", value))"
    }

    public static func remembered(userId: String, truncated: Bool = false, evicted: Int = 0) -> String {
        var text = "Remembered for \(userId)."
        if truncated {
            text += " Cut to \(MemoryFactPolicy.maxFactLength) characters."
        }
        if evicted > 0 {
            text += " Dropped \(evicted == 1 ? "the oldest fact" : "the \(evicted) oldest facts") to stay at \(MemoryFactPolicy.maxFacts)."
        }
        return text
    }

    public static func forgot(index: Int) -> String {
        "Forgot fact #\(index)."
    }

    public static func switchedPersona(_ name: String) -> String {
        "Switched to \(name)."
    }

    public static func forgetFailed(_ error: any Error) -> String {
        "Failed to forget: \(OperatorFacingError.message(error))"
    }

    public static func rememberFailed(_ error: any Error) -> String {
        "Failed to remember: \(OperatorFacingError.message(error))"
    }

    public static func voiceJoined(channelId: String) -> String {
        "Requested join for voice channel \(channelId) — presence only (muted & deafened, no audio)."
    }

    public static func voiceLeft(guildId: String) -> String {
        "Requested leave from voice in server \(guildId) — presence only (no audio)."
    }

    public static func voiceMuteDeafenUpdated(selfMute: Bool, selfDeaf: Bool) -> String {
        "Requested presence update — self-mute: \(selfMute), self-deaf: \(selfDeaf) (no audio exists to silence)."
    }

    public static func voiceStatus(guildId: String?, channelId: String?) -> String {
        guard let guildId, let channelId, !guildId.isEmpty, !channelId.isEmpty else {
            return "Not in a voice channel (presence only when joined — no audio)."
        }
        return "In voice channel \(channelId) (guild \(guildId)) — presence only, no audio."
    }

    public static func modelCurrent(_ display: String) -> String {
        "Inference backend: **\(display)**"
    }

    public static func modelSet(_ display: String) -> String {
        "Inference backend set to **\(display)**. `/ask`, `/explain`, `/summarize`, and chat replies use this path (Foundation Models when `onDevice`)."
    }

    public static func equityResult(symbol: String, score: Double, factors: String) -> String {
        """
        **\(symbol)** synthetic score: \(String(format: "%.3f", score))
        Factors: \(factors)
        \(equityDisclaimer)
        """
    }

    public static func industryProfile(_ name: String, suffixEmpty: Bool) -> String {
        if suffixEmpty {
            return "Industry profile: **\(name)** (no extra prompt overlay)."
        }
        return "Industry profile: **\(name)** (prompt overlay active for persona replies)."
    }

    public static func ping(latencyMs: Double) -> String {
        "Pong — bot loop \(String(format: "%.1f", latencyMs)) ms"
    }

    public static func statusReport(
        persona: String,
        inference: String,
        discord: String,
        messages: Int,
        inferenceCalls: Int,
        inferenceFailures: Int,
        lastInferenceError: String,
        industry: String,
        equityEnabled: Bool,
        dryRun: Bool,
        delayedRewards: Bool = true,
        replayBufferCount: Int? = nil
    ) -> String {
        var lines = [
            "**AbbeyBot status**",
            "Persona: \(persona)",
            "Inference: \(inference)",
            "Discord: \(discord)",
            "Industry: \(industry)",
            "Equity module: \(equityEnabled ? "on" : "off")",
            "Dry-run: \(dryRun ? "yes" : "no")",
            "Session messages: \(messages)",
            "Inference calls: \(inferenceCalls) (failures: \(inferenceFailures))",
        ]
        if !lastInferenceError.isEmpty {
            lines.append("Last inference error: \(lastInferenceError)")
        }
        lines.append("Backends: Foundation Models · remote OpenAI-compatible · deterministic floor · Fluent/SwiftData · optional Twitch")
        lines.append("Self-learn: DQN \(DQNAgent.defaultTopology) · \(NeuralMath.accelerationBackend) · local WDBX `~/.abbey/wdbx/`")
        lines.append("Delayed rewards: \(delayedRewards ? "on" : "off")")
        if let replayBufferCount {
            lines.append("Replay buffer: \(replayBufferCount)")
        }
        return lines.joined(separator: "\n")
    }
}
