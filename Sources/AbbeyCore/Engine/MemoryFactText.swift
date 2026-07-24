import Foundation

/// Strips leading "remember" / "note that" from a memory-store utterance.
public enum MemoryFactText: Sendable {
    public static func extract(from content: String) -> String {
        content
            .replacingOccurrences(of: #"(?i)^(remember|note that)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
