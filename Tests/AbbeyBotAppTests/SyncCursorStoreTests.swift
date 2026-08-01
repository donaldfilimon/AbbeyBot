import AbbeyCore
import Foundation
import Testing

@testable import AbbeyBotApp

@Suite("SyncCursorStore persistence")
struct SyncCursorStoreTests {
    /// Isolated defaults per test so cases can't leak into each other or into the real app domain.
    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func returnsNilBeforeAnyPullHasSucceeded() {
        let store = SyncCursorStore(defaults: makeDefaults())

        #expect(store.lastPullSuccessAt == nil)
    }

    @Test func roundTripsARecordedCursor() {
        let defaults = makeDefaults()
        let store = SyncCursorStore(defaults: defaults)
        let cursor = Date(timeIntervalSince1970: 1_700_000_000)

        store.record(cursor)

        #expect(store.lastPullSuccessAt == cursor)
    }

    /// The whole point of persisting: a fresh store over the same defaults (i.e. next launch)
    /// still sees the cursor, so the first pull of a session is incremental too.
    @Test func survivesAcrossStoreInstances() {
        let defaults = makeDefaults()
        let cursor = Date(timeIntervalSince1970: 1_712_345_678)
        SyncCursorStore(defaults: defaults).record(cursor)

        let reloaded = SyncCursorStore(defaults: defaults)

        #expect(reloaded.lastPullSuccessAt == cursor)
    }

    @Test func recordOverwritesAnEarlierCursor() {
        let defaults = makeDefaults()
        let store = SyncCursorStore(defaults: defaults)
        store.record(Date(timeIntervalSince1970: 1_000))

        store.record(Date(timeIntervalSince1970: 2_000))

        #expect(store.lastPullSuccessAt == Date(timeIntervalSince1970: 2_000))
    }

    @Test func clearResetsToFullWindow() {
        let defaults = makeDefaults()
        let store = SyncCursorStore(defaults: defaults)
        store.record(Date(timeIntervalSince1970: 1_700_000_000))

        store.clear()

        #expect(store.lastPullSuccessAt == nil)
    }

    /// A corrupted/foreign value must degrade to a full pull rather than crashing or
    /// producing a bogus cursor that silently skips rows.
    @Test func treatsNonNumericStoredValueAsNoCursor() {
        let defaults = makeDefaults()
        defaults.set("not a date", forKey: SyncCursorStore.defaultsKey)

        #expect(SyncCursorStore(defaults: defaults).lastPullSuccessAt == nil)
    }

    /// Failed pulls must not advance the cursor — otherwise rows never applied would be
    /// skipped forever on the next attempt.
    @Test func failedPullLeavesCursorUnchanged() {
        let defaults = makeDefaults()
        let store = SyncCursorStore(defaults: defaults)
        let prior = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(prior)

        store.applyPullOutcome(nextCursor: Date(timeIntervalSince1970: 1_800_000_000), succeeded: false)

        #expect(store.lastPullSuccessAt == prior)
    }

    /// The pull planner may select a returned full-page boundary instead of pull start.
    @Test func successfulPullRecordsPlannedCursor() {
        let defaults = makeDefaults()
        let store = SyncCursorStore(defaults: defaults)
        let attemptStartedAt = Date(timeIntervalSince1970: 1_700_000_100)

        store.applyPullOutcome(nextCursor: attemptStartedAt, succeeded: true)

        #expect(store.lastPullSuccessAt == attemptStartedAt)
    }

    @Test func successfulNilCursorResetsToFullPull() {
        let defaults = makeDefaults()
        let store = SyncCursorStore(defaults: defaults)
        store.record(Date(timeIntervalSince1970: 1_700_000_000))

        store.applyPullOutcome(nextCursor: nil, succeeded: true)

        #expect(store.lastPullSuccessAt == nil)
    }

    @Test func legacyTimestampMigratesIntoEveryEntityCursor() {
        let defaults = makeDefaults()
        let legacy = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(legacy.timeIntervalSince1970, forKey: SyncCursorStore.defaultsKey)

        let cursors = SyncCursorStore(defaults: defaults).pullCursors

        for entity in SyncPullEntity.allCases {
            #expect(cursors[entity] == SyncPullCursor(changedAt: legacy))
        }
    }

    @Test func compoundCursorSetRoundTripsAndReplacesLegacyKey() {
        let defaults = makeDefaults()
        defaults.set(100.0, forKey: SyncCursorStore.defaultsKey)
        let store = SyncCursorStore(defaults: defaults)
        let expected = SyncPullCursorSet(
            users: SyncPullCursor(changedAt: Date(timeIntervalSince1970: 200), stableID: "g:u"),
            messages: SyncPullCursor(changedAt: Date(timeIntervalSince1970: 300), stableID: "m-0500")
        )

        store.applyPullOutcome(nextCursors: expected, succeeded: true)

        #expect(SyncCursorStore(defaults: defaults).pullCursors == expected)
        #expect(defaults.object(forKey: SyncCursorStore.defaultsKey) == nil)
    }

    @Test func failedCompoundPullPreservesPreviousSet() {
        let defaults = makeDefaults()
        let store = SyncCursorStore(defaults: defaults)
        let original = SyncPullCursorSet(
            equity: SyncPullCursor(changedAt: Date(timeIntervalSince1970: 400), stableID: "ABBY")
        )
        store.record(original)

        store.applyPullOutcome(nextCursors: SyncPullCursorSet(), succeeded: false)

        #expect(store.pullCursors == original)
    }

    @Test func endpointNamespacesDoNotShareProgress() {
        let defaults = makeDefaults()
        let first = SyncCursorStore(defaults: defaults, endpoint: "HTTPS://Example.com:443/api/")
        let equivalent = SyncCursorStore(defaults: defaults, endpoint: "https://example.com/api")
        let other = SyncCursorStore(defaults: defaults, endpoint: "https://other.example/api")
        let expected = SyncPullCursorSet(
            users: SyncPullCursor(changedAt: Date(timeIntervalSince1970: 123), stableID: "g:u")
        )

        first.record(expected)

        #expect(equivalent.pullCursors == expected)
        #expect(other.pullCursors == SyncPullCursorSet())
    }
}
