import Foundation

/// Shared sentiment → DQN step used by Desktop `AbbeyEngine` and server `BotRuntime`.
/// Persistence stays in each host; this owns only the pure scoring/learning loop.
public struct IngestScoreResult: Sendable {
    public let intent: IntentClassifier.Intent
    public let action: Int
    public let quality: Double
}

public enum IngestScorer: Sendable {
    public static func scoreAndLearn(
        content: String,
        guildId: String,
        reputationBefore: Double,
        authorInteractionCount: Int,
        channelMessageCount: Int,
        dqnAgent: DQNAgent,
        intent: IntentClassifier.Intent? = nil,
        recentReactionCount: Int = 0,
        mentionsSomeone: Bool? = nil,
        isReply: Bool = false,
        timestamp: Date = .now
    ) async -> IngestScoreResult {
        let intent = intent ?? IntentClassifier.classify(content)
        let fullState = SentimentAnalyzer.analyze(
            text: content,
            authorReputation: reputationBefore,
            recentReactionCount: recentReactionCount,
            mentionsSomeone: mentionsSomeone ?? content.contains("@"),
            isReply: isReply,
            timestamp: timestamp,
            channelMessageCountInWindow: channelMessageCount,
            authorInteractionCount: authorInteractionCount,
            isDirectMessage: guildId == "DM"
        )
        let state = SentimentAnalyzer.projectToNetworkInput(fullState)
        let action = await dqnAgent.selectAction(state: state)
        await dqnAgent.remember(
            Experience(state: state, action: action, reward: Float(intent.quality), nextState: state, done: true)
        )
        await dqnAgent.learn()
        return IngestScoreResult(intent: intent, action: action, quality: intent.quality)
    }

    public static func latencyMilliseconds(since started: ContinuousClock.Instant) -> Double {
        let elapsed = started.duration(to: .now)
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }
}
