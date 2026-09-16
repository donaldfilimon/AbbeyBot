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

/// Rewards for the moderation-side signals.
public enum ModerationReward {
    /// Abbey's reply was deleted, by anyone, while its sample was still tracked.
    public static let replyDeleted: Float = -1.5

    /// A moderator confirmed a destructive action against the author of a tracked
    /// message. `nil` means the strategy carries no signal for that outcome.
    public static func value(forConfirmedActionAfter strategy: StrategyAction) -> Float? {
        switch strategy {
        case .answer, .clarify: return -1
        case .refuse: return 1
        case .retrieve: return nil
        }
    }
}

/// Links Abbey's strategy choices to the human outcomes that follow them, so those
/// outcomes can train the DQN. See
/// `docs/superpowers/specs/2026-09-16-abbey-delayed-rewards-design.md`.
///
/// Flow: ingest `stage`s the sample under the user's message id; the reply path `bind`s it
/// to the id of the message Abbey sent. Three signals then consume samples:
/// a reaction from the addressed user on the reply, the reply's deletion, and a confirmed
/// moderation action against the author. Every sample pays out at most once.
///
/// **Claim-honest:** each resulting `Experience` is a second terminal contextual-bandit
/// sample for the same (state, action) that `IngestScorer` already recorded with its
/// heuristic reward. It is not an MDP transition and does not bootstrap. Unit-tested; not
/// yet observed against a live gateway.
public actor DelayedRewardLedger {
    struct Pending: Sendable {
        let authorId: String
        let guildId: String
        let state: [Float]
        let action: Int
        let stagedAt: Date

        func experience(reward: Float) -> Experience {
            Experience(state: state, action: action, reward: reward, nextState: state, done: true)
        }
    }

    /// Upper bound on samples one moderation confirmation can pay out.
    public static let moderationPayoutLimit = 20

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
        guildId: String = "",
        state: [Float],
        action: Int,
        now: Date = .now
    ) {
        guard isEnabled, !sourceMessageId.isEmpty, !authorId.isEmpty else { return }
        Self.insert(
            Pending(authorId: authorId, guildId: guildId, state: state, action: action, stagedAt: now),
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

    /// Reaction signal. Consumes the bound entry when the reaction carries a signal and
    /// comes from the user Abbey replied to. A neutral emoji leaves the entry in place.
    public func reward(
        replyMessageId: String,
        reactorId: String,
        botUserId: String?,
        emojiName: String?,
        isCustomEmoji: Bool,
        now: Date = .now
    ) -> Experience? {
        if let botUserId, reactorId == botUserId { return nil }
        guard let pending = liveBound(replyMessageId, now: now),
              pending.authorId == reactorId,
              let value = ReactionReward.value(emojiName: emojiName, isCustom: isCustomEmoji) else {
            return nil
        }
        bound.removeValue(forKey: replyMessageId)
        return pending.experience(reward: value)
    }

    /// Deletion signal: Abbey's reply was removed while its sample was still tracked.
    public func consumeReplyDeletion(replyMessageId: String, now: Date = .now) -> Experience? {
        guard let pending = liveBound(replyMessageId, now: now) else { return nil }
        bound.removeValue(forKey: replyMessageId)
        return pending.experience(reward: ModerationReward.replyDeleted)
    }

    /// Moderation signal: a destructive action against `targetUserId` in `guildId` was
    /// confirmed. Pays out the target's live samples (staged or bound), newest first, up to
    /// `moderationPayoutLimit`. Samples whose strategy carries no signal are kept.
    public func consumeModeration(targetUserId: String, guildId: String, now: Date = .now) -> [Experience] {
        guard !targetUserId.isEmpty else { return [] }
        let matches = { (pending: Pending) in
            pending.authorId == targetUserId
                && pending.guildId == guildId
                && !self.isExpired(pending, now: now)
                && ModerationReward.value(forConfirmedActionAfter: StrategyAction.from(raw: pending.action)) != nil
        }
        // Tables hold at most `capacity` entries each, so a scan is cheap and needs no
        // secondary index to keep consistent.
        let candidates = (staged.filter { matches($0.value) }.map { (key: $0.key, isBound: false, pending: $0.value) }
            + bound.filter { matches($0.value) }.map { (key: $0.key, isBound: true, pending: $0.value) })
            .sorted { $0.pending.stagedAt > $1.pending.stagedAt }
            .prefix(Self.moderationPayoutLimit)

        var experiences: [Experience] = []
        for candidate in candidates {
            if candidate.isBound {
                bound.removeValue(forKey: candidate.key)
            } else {
                staged.removeValue(forKey: candidate.key)
            }
            if let value = ModerationReward.value(
                forConfirmedActionAfter: StrategyAction.from(raw: candidate.pending.action)
            ) {
                experiences.append(candidate.pending.experience(reward: value))
            }
        }
        return experiences
    }

    private func liveBound(_ replyMessageId: String, now: Date) -> Pending? {
        guard let pending = bound[replyMessageId] else { return nil }
        if isExpired(pending, now: now) {
            bound.removeValue(forKey: replyMessageId)
            return nil
        }
        return pending
    }

    private nonisolated func isExpired(_ pending: Pending, now: Date) -> Bool {
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
