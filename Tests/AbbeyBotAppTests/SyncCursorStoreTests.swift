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

        store.applyPullOutcome(attemptStartedAt: Date(timeIntervalSince1970: 1_800_000_000), succeeded: false)

        #expect(store.lastPullSuccessAt == prior)
    }

    /// Success stamps the attempt *start*, not completion, so in-flight server writes
    /// are refetched next time instead of being skipped permanently.
    @Test func successfulPullRecordsAttemptStartNotALaterTime() {
        let defaults = makeDefaults()
        let store = SyncCursorStore(defaults: defaults)
        let attemptStartedAt = Date(timeIntervalSince1970: 1_700_000_100)

        store.applyPullOutcome(attemptStartedAt: attemptStartedAt, succeeded: true)

        #expect(store.lastPullSuccessAt == attemptStartedAt)
    }
}
