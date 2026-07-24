import Foundation

/// Shared reply-cooldown bookkeeping for desktop and server schedulers.
public struct ReplyCooldownTracker: Sendable {
    private var lastReplyAt: [String: Date] = [:]

    public init() {}

    public mutating func isCoolingDown(
        userId: String,
        guildId: String,
        cooldownSeconds: Double,
        now: Date = .now
    ) -> Bool {
        guard let last = lastReplyAt[ReputationMath.cacheKey(userId: userId, guildId: guildId)] else {
            return false
        }
        return now.timeIntervalSince(last) < cooldownSeconds
    }

    public mutating func markReplied(userId: String, guildId: String, at date: Date = .now) {
        lastReplyAt[ReputationMath.cacheKey(userId: userId, guildId: guildId)] = date
    }
}
