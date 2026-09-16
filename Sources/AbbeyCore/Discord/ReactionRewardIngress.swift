import DiscordBM

/// Turns Discord MESSAGE_REACTION_ADD into a delayed DQN reward. Shared by the server and
/// desktop runtimes so both learn from reactions identically.
public enum ReactionRewardIngress {
    /// Returns `true` when the reaction produced a remembered experience.
    @discardableResult
    public static func apply(
        _ payload: Gateway.MessageReactionAdd,
        botUserId: String?,
        ledger: DelayedRewardLedger,
        dqnAgent: DQNAgent
    ) async -> Bool {
        guard payload.member?.user?.bot != true else { return false }
        guard let experience = await ledger.reward(
            replyMessageId: payload.message_id.rawValue,
            reactorId: payload.user_id.rawValue,
            botUserId: botUserId,
            emojiName: payload.emoji.name,
            isCustomEmoji: payload.emoji.id != nil
        ) else {
            return false
        }
        await dqnAgent.remember(experience)
        await dqnAgent.learn()
        return true
    }
}
