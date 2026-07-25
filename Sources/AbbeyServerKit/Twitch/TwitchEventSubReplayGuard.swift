import Foundation

/// In-memory dedupe of Twitch EventSub deliveries by `Twitch-Eventsub-Message-Id`.
///
/// Twitch may retry the same message; callers should process only when `claim` returns
/// `true`. Entries older than `window` are pruned so the map cannot grow without bound
/// — aligned with the HMAC timestamp replay window (default 10 minutes).
public final class TwitchEventSubReplayGuard: @unchecked Sendable {
    public let window: TimeInterval

    private let lock = NSLock()
    private var seen: [String: Date] = [:]

    public init(window: TimeInterval = 600) {
        self.window = window
    }

    /// Returns `true` the first time `messageId` is seen within `window` (process it).
    /// Returns `false` on a replay (ack 2xx without reprocessing).
    public func claim(_ messageId: String, now: Date = Date()) -> Bool {
        let trimmed = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        lock.lock()
        defer { lock.unlock() }

        pruneExpiredLocked(now: now)
        if seen[trimmed] != nil {
            return false
        }
        seen[trimmed] = now
        return true
    }

    /// Test/introspection helper — count of ids retained after pruning at `now`.
    public func retainedCount(now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        pruneExpiredLocked(now: now)
        return seen.count
    }

    private func pruneExpiredLocked(now: Date) {
        seen = seen.filter { now.timeIntervalSince($0.value) <= window }
    }
}
