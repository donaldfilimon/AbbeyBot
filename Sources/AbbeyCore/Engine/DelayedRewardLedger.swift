import Foundation

/// Maps a reaction emoji to a delayed reward. Deliberately small and explicit: an emoji
/// that is not listed, and every custom guild emoji, carries no signal.
public enum ReactionReward {
    public static let positive: Float = 1
    public static let negative: Float = -1

    private static let positiveNames: Set<String> = ["👍", "❤️", "❤", "🔥", "🎉", "✅", "💯", "🙏"]
    private static let negativeNames: Set<String> = ["👎", "❌", "😕", "😡", "🙄"]

    /// `nil` means "no signal", which is different from a zero reward.
    public static func value(emojiName: String?, isCustom: Bool) -> Float? {
        guard !isCustom, let emojiName else { return nil }
        if positiveNames.contains(emojiName) { return positive }
        if negativeNames.contains(emojiName) { return negative }
        return nil
    }
}

/// Links a bot reply back to the (state, action) sample whose strategy produced it, so
/// the addressed user's reaction on that reply can train the DQN.
///
/// Flow: ingest `stage`s the sample under the user's message id; the reply path `bind`s it
/// to the id of the message Abbey sent; a reaction on that reply is turned into an
/// `Experience` by `reward`, at most once per reply.
///
/// **Claim-honest:** the resulting `Experience` is a second terminal contextual-bandit
/// sample for the same (state, action) that `IngestScorer` already recorded with its
/// heuristic reward. It is not an MDP transition and does not bootstrap. Only the user
/// Abbey replied to can reward a reply, which bounds brigading to that user's own
/// conversation. Unit-tested; not yet observed against a live gateway.
public actor DelayedRewardLedger {
    struct Pending: Sendable {
        let authorId: String
        let state: [Float]
        let action: Int
        let stagedAt: Date
    }

    public let capacity: Int
    public let timeToLive: TimeInterval
    /// Fixed at init from `AppConfig.delayedRewardsEnabled`. When false nothing is staged,
    /// so every signal is a no-op and re-enabling never replays earlier traffic.
    public nonisolated let isEnabled: Bool

    private var staged: [String: Pending] = [:]
    private var bound: [String: Pending] = [:]

    public init(capacity: Int = 512, timeToLive: TimeInterval = 24 * 60 * 60, isEnabled: Bool = true) {
        self.capacity = max(1, capacity)
        self.timeToLive = max(0, timeToLive)
        self.isEnabled = isEnabled
    }

    public var stagedCount: Int { staged.count }
    public var boundCount: Int { bound.count }

    public func stage(
        sourceMessageId: String,
        authorId: String,
        state: [Float],
        action: Int,
        now: Date = .now
    ) {
        guard isEnabled, !sourceMessageId.isEmpty, !authorId.isEmpty else { return }
        Self.insert(
            Pending(authorId: authorId, state: state, action: action, stagedAt: now),
            key: sourceMessageId,
            into: &staged,
            capacity: capacity,
            timeToLive: timeToLive,
            now: now
        )
    }

    /// Returns `false` when nothing was staged for the source (duplicate, evicted, expired).
    @discardableResult
    public func bind(sourceMessageId: String, replyMessageId: String, now: Date = .now) -> Bool {
        guard !replyMessageId.isEmpty, let pending = staged.removeValue(forKey: sourceMessageId) else {
            return false
        }
        guard !isExpired(pending, now: now) else { return false }
        Self.insert(
            pending,
            key: replyMessageId,
            into: &bound,
            capacity: capacity,
            timeToLive: timeToLive,
            now: now
        )
        return true
    }

    /// Consumes the bound entry when the reaction carries a signal and comes from the user
    /// Abbey replied to. A neutral emoji leaves the entry in place for a later reaction.
    public func reward(
        replyMessageId: String,
        reactorId: String,
        botUserId: String?,
        emojiName: String?,
        isCustomEmoji: Bool,
        now: Date = .now
    ) -> Experience? {
        if let botUserId, reactorId == botUserId { return nil }
        guard let pending = bound[replyMessageId] else { return nil }
        if isExpired(pending, now: now) {
            bound.removeValue(forKey: replyMessageId)
            return nil
        }
        guard pending.authorId == reactorId,
              let value = ReactionReward.value(emojiName: emojiName, isCustom: isCustomEmoji) else {
            return nil
        }
        bound.removeValue(forKey: replyMessageId)
        return Experience(
            state: pending.state,
            action: pending.action,
            reward: value,
            nextState: pending.state,
            done: true
        )
    }

    private func isExpired(_ pending: Pending, now: Date) -> Bool {
        now.timeIntervalSince(pending.stagedAt) > timeToLive
    }

    private static func insert(
        _ pending: Pending,
        key: String,
        into table: inout [String: Pending],
        capacity: Int,
        timeToLive: TimeInterval,
        now: Date
    ) {
        if table[key] == nil, table.count >= capacity {
            table = table.filter { now.timeIntervalSince($0.value.stagedAt) <= timeToLive }
            if table.count >= capacity,
               let oldest = table.min(by: { $0.value.stagedAt < $1.value.stagedAt })?.key {
                table.removeValue(forKey: oldest)
            }
        }
        table[key] = pending
    }
}
