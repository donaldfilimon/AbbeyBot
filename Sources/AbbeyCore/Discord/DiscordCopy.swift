import Foundation

/// User-facing Discord / slash-command copy shared by Desktop and AbbeyServer.
public enum DiscordCopy: Sendable {
    public static let engineUnavailable = "Engine unavailable."
    public static let noMemory = "No memory for that user."
    public static let invalidFactIndex = "Invalid fact index."
    public static let noChannelSummary = "No channel summary yet."

    /// Voice presence MVP — never claim audio capture or playback.
    public static let voiceNotConnected = "Not connected to Discord — connect before joining voice."
    public static let voiceMissingGuild = "Need a server (guild) id to join or leave voice."
    public static let voiceMissingChannel = "Need a voice channel id to join."
    public static let voiceLeaveFailed = "Could not leave voice — gateway not ready (presence only — no audio)."
    public static let voiceDryRunNoGateway =
        "Dry-run mode — Discord gateway is not active; voice presence unavailable (connect live for presence only — no audio)."
    public static let voiceUnknownSubcommand = "Use `/voice join` or `/voice leave` (presence only — no audio)."
    public static let voicePresenceOnly = "Presence only — muted & deafened; no audio (DiscordBM has no Opus/UDP)."

    public static func reputation(userId: String, value: Double) -> String {
        "Reputation for \(userId): \(String(format: "%.3f", value))"
    }

    public static func remembered(userId: String) -> String {
        "Remembered for \(userId)."
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

    public static func voiceStatus(guildId: String?, channelId: String?) -> String {
        guard let guildId, let channelId, !guildId.isEmpty, !channelId.isEmpty else {
            return "Not in a voice channel (presence only when joined — no audio)."
        }
        return "In voice channel \(channelId) (guild \(guildId)) — presence only, no audio."
    }
}
