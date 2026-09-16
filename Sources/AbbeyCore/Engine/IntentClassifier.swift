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
        if ["kick", "ban", "purge", "timeout", "mod"].contains(where: { containsWord($0, in: lower) }) {
            return .modRequest
        }
        if containsWord("remember", in: lower) || lower.contains("note that") { return .memoryStore }
        if containsWord("rep", in: lower) || containsWord("reputation", in: lower) { return .repQuery }
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

    /// Whole-word containment.
    ///
    /// These rules previously used bare `contains`, which matches inside other
    /// words: "report" and "reply" scored as reputation queries, and "banana"
    /// and "kickoff" as moderation requests. That is worse than a wrong reply —
    /// `Intent.quality` feeds `recordInteraction` and the DQN, so a
    /// misclassification writes corrupted signal into reputation and learning.
    /// The persona rule below was already `\b`-anchored for this exact reason.
    private static func containsWord(_ word: String, in text: String) -> Bool {
        text.range(of: #"\b\#(word)\b"#, options: .regularExpression) != nil
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
