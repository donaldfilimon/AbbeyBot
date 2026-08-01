import Foundation

/// DQN output head — strategies the bot may take when crafting a reply.
/// Index matches `DQNAgent.defaultTopology` last layer width (4).
public enum StrategyAction: Int, CaseIterable, Sendable, Codable {
    case answer = 0
    case clarify = 1
    case retrieve = 2
    case refuse = 3

    public var label: String {
        switch self {
        case .answer: return "answer"
        case .clarify: return "clarify"
        case .retrieve: return "retrieve"
        case .refuse: return "refuse"
        }
    }

    public static func from(raw: Int) -> StrategyAction {
        StrategyAction(rawValue: raw) ?? .answer
    }

    /// Prompt prefix / shaping applied when generating a persona reply for this strategy.
    public func replyDirective(userText: String, retrievedFacts: [String]) -> String {
        switch self {
        case .answer:
            return userText
        case .clarify:
            return """
            The user said: \(userText)

            Ask one or two clarifying questions before giving a full answer. Be brief.
            """
        case .retrieve:
            let facts = retrievedFacts.isEmpty
                ? "(no stored facts — say what you would look up)"
                : retrievedFacts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            return """
            Use the retrieved memory below to answer. If memory is insufficient, say so.

            Memory:
            \(facts)

            User: \(userText)
            """
        case .refuse:
            return """
            The user said: \(userText)

            Politely decline or set a boundary if the request is unsafe, out of scope, or needs a human moderator. \
            Offer a constructive alternative when possible. Do not invent that you took moderation actions.
            """
        }
    }

    /// Immediate reward shaping for the chosen strategy given intent (before delayed feedback).
    public func shapedReward(intent: IntentClassifier.Intent, quality: Double) -> Float {
        let base = Float(quality)
        switch (self, intent) {
        case (.answer, .question), (.answer, .greeting), (.answer, .smallTalk):
            return base + 0.05
        case (.clarify, .question):
            return base + 0.08
        case (.clarify, .unknown):
            return base + 0.1
        case (.retrieve, .memoryStore), (.retrieve, .question):
            return base + 0.1
        case (.refuse, .modRequest), (.refuse, .command):
            return base + 0.15
        case (.refuse, .question):
            return base - 0.05 // answering questions is usually better
        case (.answer, .modRequest):
            return base - 0.1 // mod should prefer refuse/escalate path
        default:
            return base
        }
    }
}
