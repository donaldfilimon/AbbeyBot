import AbbeyServerKit
import Foundation
import Testing

/// Core claim semantics. These used to run against an in-memory map; the guard is now
/// database-backed, so each case gets a fresh migrated sqlite database (see
/// `withReplayGuardDatabase` in TwitchEventSubReplayGuardPersistenceTests).
/// `.serialized` for the same reason as the sibling persistence suite: the shared harness
/// mutates process-global environment variables, which is not safe to race.
@Suite("Twitch EventSub message-id replay guard", .serialized)
struct TwitchEventSubReplayGuardTests {
    @Test func firstClaimSucceeds() async throws {
        try await withReplayGuardDatabase { db in
            let guard_ = TwitchEventSubReplayGuard()
            let claimed = try await guard_.claim("msg-1", now: Date(timeIntervalSince1970: 1_000), on: db)
            #expect(claimed)
        }
    }

    @Test func duplicateClaimIsRejected() async throws {
        try await withReplayGuardDatabase { db in
            let guard_ = TwitchEventSubReplayGuard()
            let now = Date(timeIntervalSince1970: 1_000)
            let first = try await guard_.claim("msg-1", now: now, on: db)
            let replay = try await guard_.claim("msg-1", now: now.addingTimeInterval(30), on: db)
            #expect(first)
            #expect(!replay)
        }
    }

    @Test func distinctIdsAreIndependent() async throws {
        try await withReplayGuardDatabase { db in
            let guard_ = TwitchEventSubReplayGuard()
            let now = Date(timeIntervalSince1970: 1_000)
            let first = try await guard_.claim("msg-a", now: now, on: db)
            let second = try await guard_.claim("msg-b", now: now, on: db)
            #expect(first)
            #expect(second)
        }
    }

    @Test func emptyMessageIdDoesNotBlockProcessing() async throws {
        try await withReplayGuardDatabase { db in
            let guard_ = TwitchEventSubReplayGuard()
            let whitespace = try await guard_.claim("   ", now: Date(timeIntervalSince1970: 1_000), on: db)
            let empty = try await guard_.claim("", now: Date(timeIntervalSince1970: 1_000), on: db)
            #expect(whitespace)
            #expect(empty)
        }
    }

    @Test func expiredIdsCanBeClaimedAgain() async throws {
        try await withReplayGuardDatabase { db in
            let guard_ = TwitchEventSubReplayGuard(window: 600)
            let t0 = Date(timeIntervalSince1970: 1_000)
            let first = try await guard_.claim("msg-1", now: t0, on: db)
            // Just past the window — pruned, so claim succeeds again.
            let afterExpiry = try await guard_.claim("msg-1", now: t0.addingTimeInterval(601), on: db)
            #expect(first)
            #expect(afterExpiry)
        }
    }

    @Test func pruneDropsStaleEntriesFromCount() async throws {
        try await withReplayGuardDatabase { db in
            let guard_ = TwitchEventSubReplayGuard(window: 600)
            let t0 = Date(timeIntervalSince1970: 1_000)
            let old = try await guard_.claim("old", now: t0, on: db)
            let fresh = try await guard_.claim("fresh", now: t0.addingTimeInterval(500), on: db)
            let retained = try await guard_.retainedCount(now: t0.addingTimeInterval(601), on: db)
            #expect(old)
            #expect(fresh)
            #expect(retained == 1)
        }
    }
}
