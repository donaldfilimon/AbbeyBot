import AbbeyServerKit
import Foundation
import Testing

@Suite("Twitch EventSub message-id replay guard")
struct TwitchEventSubReplayGuardTests {
    @Test func firstClaimSucceeds() {
        let guard_ = TwitchEventSubReplayGuard()
        #expect(guard_.claim("msg-1", now: Date(timeIntervalSince1970: 1_000)))
    }

    @Test func duplicateClaimIsRejected() {
        let guard_ = TwitchEventSubReplayGuard()
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(guard_.claim("msg-1", now: now))
        #expect(!guard_.claim("msg-1", now: now.addingTimeInterval(30)))
    }

    @Test func distinctIdsAreIndependent() {
        let guard_ = TwitchEventSubReplayGuard()
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(guard_.claim("msg-a", now: now))
        #expect(guard_.claim("msg-b", now: now))
    }

    @Test func emptyMessageIdDoesNotBlockProcessing() {
        let guard_ = TwitchEventSubReplayGuard()
        #expect(guard_.claim("   ", now: Date(timeIntervalSince1970: 1_000)))
        #expect(guard_.claim("", now: Date(timeIntervalSince1970: 1_000)))
    }

    @Test func expiredIdsCanBeClaimedAgain() {
        let guard_ = TwitchEventSubReplayGuard(window: 600)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(guard_.claim("msg-1", now: t0))
        // Just past the window — pruned, so claim succeeds again.
        #expect(guard_.claim("msg-1", now: t0.addingTimeInterval(601)))
    }

    @Test func pruneDropsStaleEntriesFromCount() {
        let guard_ = TwitchEventSubReplayGuard(window: 600)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(guard_.claim("old", now: t0))
        #expect(guard_.claim("fresh", now: t0.addingTimeInterval(500)))
        #expect(guard_.retainedCount(now: t0.addingTimeInterval(601)) == 1)
    }
}
