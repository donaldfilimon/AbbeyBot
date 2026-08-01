import Fluent
import Foundation

/// Durable dedupe of Twitch EventSub deliveries by `Twitch-Eventsub-Message-Id`.
///
/// Twitch retries the same message aggressively; callers should process only when `claim`
/// returns `true`. Claims live in the `twitch_eventsub_deliveries` table rather than in
/// process memory, so a restart — or a second instance sharing the database — still reports
/// an already-acked delivery as a duplicate instead of re-ingesting it.
///
/// Atomicity comes from the unique constraint on `message_id`: the insert *is* the claim, so
/// two concurrent deliveries of one id cannot both win. Entries older than `window` are
/// pruned on every claim, so the table cannot grow without bound — aligned with the HMAC
/// timestamp replay window (default 10 minutes).
///
/// The guard holds no mutable state of its own; every operation is a database call.
public final class TwitchEventSubReplayGuard: Sendable {
    public let window: TimeInterval

    public init(window: TimeInterval = 600) {
        self.window = window
    }

    /// Returns `true` the first time `messageId` is seen within `window` (process it).
    /// Returns `false` on a replay (ack 2xx without reprocessing).
    ///
    /// Empty/whitespace ids are unclaimable and always return `true` — there is nothing to
    /// dedupe on, so the caller must process. Throws only on real database failures; callers
    /// should turn that into a retryable response rather than processing unguarded.
    ///
    /// Must be called on an autocommit connection, never inside a caller-opened
    /// `db.transaction { }`: Postgres aborts the whole enclosing transaction on a unique
    /// violation, so swallowing it here would poison every later statement in that unit of
    /// work. SQLite does not, which is why no test can catch that mistake.
    public func claim(
        _ messageId: String,
        now: Date = Date(),
        on db: any Database
    ) async throws -> Bool {
        let trimmed = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Prune first so an id whose claim has aged past `window` is claimable again.
        try await pruneExpired(now: now, on: db)

        do {
            try await TwitchEventSubDelivery(messageId: trimmed, claimedAt: now).create(on: db)
            return true
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // The unique index rejected us: someone else already owns this delivery id.
            return false
        }
    }

    /// Release a provisional claim after retryable processing failed. Twitch can then retry
    /// the same delivery id; successful deliveries remain claimed for the replay window.
    ///
    /// Deleting the row is what makes a released id re-claimable — the next `claim` inserts
    /// afresh and wins.
    public func release(_ messageId: String, on db: any Database) async throws {
        let trimmed = messageId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await TwitchEventSubDelivery.query(on: db)
            .filter(\.$messageId == trimmed)
            .delete()
    }

    /// Test/introspection helper — count of ids retained after pruning at `now`.
    public func retainedCount(now: Date = Date(), on db: any Database) async throws -> Int {
        try await pruneExpired(now: now, on: db)
        return try await TwitchEventSubDelivery.query(on: db).count()
    }

    /// Drops claims strictly older than `window`. A no-op on an empty/fresh table.
    private func pruneExpired(now: Date, on db: any Database) async throws {
        let cutoff = now.addingTimeInterval(-window)
        try await TwitchEventSubDelivery.query(on: db)
            .filter(\.$claimedAt < cutoff)
            .delete()
    }
}
