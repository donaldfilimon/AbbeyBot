import Foundation

/// User-facing Discord / slash-command copy shared by Desktop and AbbeyServer.
public enum DiscordCopy: Sendable {
    public static let engineUnavailable = "Engine unavailable."
    public static let noMemory = "No memory for that user."
    public static let invalidFactIndex = "Invalid fact index."
    public static let noChannelSummary = "No channel summary yet."

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
        "Failed to forget: \(error)"
    }

    public static func rememberFailed(_ error: any Error) -> String {
        "Failed to remember: \(error)"
    }
}
