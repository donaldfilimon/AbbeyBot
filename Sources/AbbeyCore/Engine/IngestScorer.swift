import Foundation

/// Shared sentiment → DQN step used by Desktop `AbbeyEngine` and server `BotRuntime`.
/// Persistence stays in each host; this owns scoring, strategy selection, and learning.
public struct IngestScoreResult: Sendable {
    public let intent: IntentClassifier.Intent
    public let action: Int
    public let strategy: StrategyAction
    public let quality: Double
    public let state: [Float]
    public let reward: Float

    public init(
        intent: IntentClassifier.Intent,
        action: Int,
        strategy: StrategyAction,
        quality: Double,
        state: [Float],
        reward: Float
    ) {
        self.intent = intent
        self.action = action
        self.strategy = strategy
        self.quality = quality
        self.state = state
        self.reward = reward
    }
}

public enum IngestScorer: Sendable {
    /// Select strategy, write experience (action-conditioned reward), train one step, upsert into local WDBX.
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
        timestamp: Date = .now,
        wdbx: WDBXStore? = nil,
        authorId: String = "",
        channelId: String = ""
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
        let strategy = StrategyAction.from(raw: action)
        let reward = strategy.shapedReward(intent: intent, quality: intent.quality)

        // This signal is available immediately, before any user reaction or moderation
        // outcome. Model it honestly as a terminal contextual-bandit sample instead of
        // inventing a future state and bootstrapping from synthetic dynamics.
        let nextState = state
        let done = true

        await dqnAgent.remember(
            Experience(state: state, action: action, reward: reward, nextState: nextState, done: done)
        )
        await dqnAgent.learn()

        if let wdbx {
            try? wdbx.upsert(
                WDBXRecord(
                    id: UUID().uuidString,
                    vector: fullState,
                    payload: [
                        "kind": "ingest",
                        "guildId": guildId,
                        "channelId": channelId,
                        "userId": authorId,
                        "strategy": strategy.label,
                        "intent": intent.rawValue,
                    ],
                    createdAt: timestamp
                )
            )
        }

        return IngestScoreResult(
            intent: intent,
            action: action,
            strategy: strategy,
            quality: intent.quality,
            state: state,
            reward: reward
        )
    }

    public static func latencyMilliseconds(since started: ContinuousClock.Instant) -> Double {
        let elapsed = started.duration(to: .now)
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }
}
