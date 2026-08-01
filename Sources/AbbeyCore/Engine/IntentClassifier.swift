import Foundation

public struct IntentClassifier {
    public enum Intent: String, CaseIterable, Sendable {
        case question, greeting, modRequest, memoryStore, personaSwitch,
             repQuery, smallTalk, command, unknown

        public var quality: Double {
            switch self {
            case .question, .modRequest, .memoryStore: return 0.8
            case .greeting, .smallTalk: return 0.5
            case .unknown: return 0.2
            default: return 0.6
            }
        }
    }

    /// Default path: lexical rules, then strict small-talk gate so empty / emoji-only
    /// messages score as `.unknown` (0.2 quality) instead of automatic `.smallTalk`.
    public static func classify(_ text: String) -> Intent {
        let result = classifyLoose(text)
        guard result == .smallTalk else { return result }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLetters = trimmed.contains { $0.isLetter }
        guard trimmed.count >= 2, hasLetters else { return .unknown }
        return .smallTalk
    }

    /// Legacy lenient path — everything unmatched becomes `.smallTalk`.
    public static func classifyLoose(_ text: String) -> Intent {
        let lower = text.lowercased()
        if lower.hasPrefix("!") || lower.hasPrefix("/") { return .command }
        if lower.contains("kick") || lower.contains("ban") || lower.contains("purge")
            || lower.contains("timeout") || lower.contains("mod ") { return .modRequest }
        if lower.contains("remember") || lower.contains("note that") { return .memoryStore }
        if lower.contains("rep") || lower.contains("reputation") { return .repQuery }
        // Align with PersonaName.resolve, but require an explicit switch phrase.
        // Ordinary questions about a programming-language `switch` are not persona commands.
        if lower.range(
            of: #"\b(?:switch\s+(?:to\s+)?|be\s+)(aviva|abi|abbey)\b"#,
            options: .regularExpression
        ) != nil {
            return .personaSwitch
        }
        if lower.hasSuffix("?") || lower.hasPrefix("what") || lower.hasPrefix("how") { return .question }
        if ["hi", "hey", "yo", "sup", "hello"].contains(where: { lower.hasPrefix($0) }) { return .greeting }
        return .smallTalk
    }

    /// Alias of `classify` (strict small-talk gate).
    public static func classifyStrict(_ text: String) -> Intent {
        classify(text)
    }

    public static func suggestCompletions(for partial: String) -> [String] {
        let corpus = [
            "what do you think about", "how does", "can you help me with",
            "remind me", "what is the reputation of"
        ]
        return corpus.filter { $0.hasPrefix(partial.lowercased()) }
    }
}
