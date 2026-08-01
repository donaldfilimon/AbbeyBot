import Foundation
import Testing
@testable import AbbeyCore

@Suite("Incremental sync cursor planning")
struct IncrementalSyncCursorTests {
    private let previous = Date(timeIntervalSince1970: 100)
    private let started = Date(timeIntervalSince1970: 1_000)

    @Test func shortPagesAdvanceThroughPullStart() {
        let next = IncrementalSyncCursor.next(
            previous: previous,
            attemptStartedAt: started,
            limit: 500,
            pages: [.init(count: 12, newestChangeAt: Date(timeIntervalSince1970: 900))]
        )

        #expect(next == started)
    }

    @Test func fullPageAdvancesOnlyThroughNewestReturnedChange() {
        let boundary = Date(timeIntervalSince1970: 600)
        let next = IncrementalSyncCursor.next(
            previous: previous,
            attemptStartedAt: started,
            limit: 500,
            pages: [.init(count: 500, newestChangeAt: boundary)]
        )

        #expect(next == boundary)
    }

    @Test func saturatedEndpointHoldsBackSharedCursor() {
        let boundary = Date(timeIntervalSince1970: 450)
        let next = IncrementalSyncCursor.next(
            previous: previous,
            attemptStartedAt: started,
            limit: 500,
            pages: [
                .init(count: 20, newestChangeAt: Date(timeIntervalSince1970: 300)),
                .init(count: 500, newestChangeAt: boundary),
                .init(count: 0, newestChangeAt: nil)
            ]
        )

        #expect(next == boundary)
    }

    @Test func missingTimestampOnFullPageRetainsPreviousCursor() {
        let next = IncrementalSyncCursor.next(
            previous: previous,
            attemptStartedAt: started,
            limit: 500,
            pages: [.init(count: 500, newestChangeAt: nil)]
        )

        #expect(next == previous)
    }

    @Test func serverClockAheadCannotAdvancePastPullStart() {
        let next = IncrementalSyncCursor.next(
            previous: previous,
            attemptStartedAt: started,
            limit: 500,
            pages: [.init(count: 500, newestChangeAt: Date(timeIntervalSince1970: 2_000))]
        )

        #expect(next == started)
    }
}
