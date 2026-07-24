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

    /// OPEN DECISION (flagged, not silently resolved — see /areas/discord-abbey-skill.md):
    /// `.unknown` is unreachable in this function as written, because `.smallTalk` is
    /// the unconditional fallback for anything that doesn't match an earlier branch.
    /// That means every message SocialBrain scores gets at least 0.5 quality
    /// (`.smallTalk`'s value) even when the classifier genuinely has no signal — so
    /// `.unknown`'s 0.2 quality value is dead code, and reputation never gets
    /// discounted for genuinely ambiguous input.
    ///
    /// Two ways to resolve this, deliberately NOT chosen here:
    ///   (a) Make `.smallTalk` require a *positive* signal (min length, recognizable
    ///       conversational shape) and fall back to `.unknown` otherwise — tightens
    ///       what counts as "small talk" but will reclassify some currently-smallTalk
    ///       messages as unknown, changing their reputation contribution.
    ///   (b) Leave classification as-is and treat `.unknown` as reserved for a future
    ///       input type (e.g. non-text content) rather than a text-classification
    ///       outcome at all — i.e. the branch isn't a bug, it's headroom.
    /// `classifyStrict(_:)` below implements (a) as an opt-in alternate path so both
    /// options exist in code; `classify(_:)` itself is unchanged from the reference
    /// draft's behavior.
    public static func classify(_ text: String) -> Intent {
        let lower = text.lowercased()
        if lower.hasPrefix("!") || lower.hasPrefix("/") { return .command }
        if lower.contains("kick") || lower.contains("ban") || lower.contains("purge")
            || lower.contains("timeout") || lower.contains("mod ") { return .modRequest }
        if lower.contains("remember") || lower.contains("note that") { return .memoryStore }
        if lower.contains("rep") || lower.contains("reputation") { return .repQuery }
        if lower.contains("switch") || lower.contains("be aviva") { return .personaSwitch }
        if lower.hasSuffix("?") || lower.hasPrefix("what") || lower.hasPrefix("how") { return .question }
        if ["hi", "hey", "yo", "sup", "hello"].contains(where: { lower.hasPrefix($0) }) { return .greeting }
        return .smallTalk
    }

    /// Opt-in variant implementing resolution (a) above: `.smallTalk` requires a
    /// minimum length and at least one alphabetic character; anything shorter or
    /// purely symbolic/emoji falls through to `.unknown` instead.
    public static func classifyStrict(_ text: String) -> Intent {
        let result = classify(text)
        guard result == .smallTalk else { return result }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLetters = trimmed.contains { $0.isLetter }
        guard trimmed.count >= 2, hasLetters else { return .unknown }
        return .smallTalk
    }

    public static func suggestCompletions(for partial: String) -> [String] {
        let corpus = [
            "what do you think about", "how does", "can you help me with",
            "remind me", "what is the reputation of"
        ]
        return corpus.filter { $0.hasPrefix(partial.lowercased()) }
    }
}
