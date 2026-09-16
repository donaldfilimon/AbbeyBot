import DiscordBM

/// Turns MESSAGE_DELETE and MESSAGE_DELETE_BULK into the deleted-reply DQN reward.
/// Shared by the server and desktop runtimes. A purge arrives as a bulk delete, so both
/// events must reach the ledger or a purged reply would escape the signal.
public enum ReplyDeletionIngress {
    /// Returns the number of experiences remembered.
    @discardableResult
    public static func apply(
        deletedMessageIds: [String],
        ledger: DelayedRewardLedger,
        dqnAgent: DQNAgent
    ) async -> Int {
        var remembered = 0
        for id in deletedMessageIds {
            guard let experience = await ledger.consumeReplyDeletion(replyMessageId: id) else { continue }
            await dqnAgent.remember(experience)
            remembered += 1
        }
        if remembered > 0 {
            await dqnAgent.learn()
        }
        return remembered
    }

    @discardableResult
    public static func apply(
        _ payload: Gateway.MessageDelete,
        ledger: DelayedRewardLedger,
        dqnAgent: DQNAgent
    ) async -> Int {
        await apply(deletedMessageIds: [payload.id.rawValue], ledger: ledger, dqnAgent: dqnAgent)
    }

    @discardableResult
    public static func apply(
        _ payload: Gateway.MessageDeleteBulk,
        ledger: DelayedRewardLedger,
        dqnAgent: DQNAgent
    ) async -> Int {
        await apply(deletedMessageIds: payload.ids.map(\.rawValue), ledger: ledger, dqnAgent: dqnAgent)
    }
}

/// Turns a confirmed destructive moderation action into DQN rewards for the target's
/// recent samples. Desktop only: the server graph has no `ConfirmationGate`.
public enum ModerationRewardIngress {
    @discardableResult
    public static func apply(
        targetUserId: String,
        guildId: String,
        ledger: DelayedRewardLedger,
        dqnAgent: DQNAgent
    ) async -> Int {
        let experiences = await ledger.consumeModeration(targetUserId: targetUserId, guildId: guildId)
        for experience in experiences {
            await dqnAgent.remember(experience)
        }
        if !experiences.isEmpty {
            await dqnAgent.learn()
        }
        return experiences.count
    }
}
