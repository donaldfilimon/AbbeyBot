import Foundation
import Testing
@testable import AbbeyCore

@Suite("Incremental sync cursor planning")
struct IncrementalSyncCursorTests {
    private let previous = Date(timeIntervalSince1970: 100)
    private let started = Date(timeIntervalSince1970: 1_000)

    @Test func compoundFullPagePreservesTimestampTieBreaker() {
        let previous = SyncPullCursor(changedAt: self.previous, stableID: "m-0001")
        let boundary = SyncPullCursor(
            changedAt: Date(timeIntervalSince1970: 600),
            stableID: "m-0500"
        )

        let next = IncrementalSyncCursor.next(
            previous: previous,
            attemptStartedAt: started,
            limit: 500,
            rowCount: 500,
            serverBoundary: boundary
        )

        #expect(next == boundary)
    }

    @Test func compoundShortPageAdvancesToPullStartWithoutTieBreaker() {
        let next = IncrementalSyncCursor.next(
            previous: SyncPullCursor(changedAt: previous, stableID: "m-0500"),
            attemptStartedAt: started,
            limit: 500,
            rowCount: 1,
            serverBoundary: SyncPullCursor(changedAt: previous, stableID: "m-0501")
        )

        #expect(next == SyncPullCursor(changedAt: started))
    }

    @Test func shortPageUsesServerHighWatermarkInsteadOfClientClock() {
        let serverHighWatermark = Date(timeIntervalSince1970: 800)
        let next = IncrementalSyncCursor.next(
            previous: SyncPullCursor(changedAt: previous),
            attemptStartedAt: Date(timeIntervalSince1970: 5_000),
            limit: 500,
            rowCount: 0,
            serverBoundary: nil,
            serverHighWatermark: serverHighWatermark
        )

        #expect(next == SyncPullCursor(changedAt: serverHighWatermark))
    }

    @Test func fullPageClampsAgainstServerHighWatermark() {
        let serverHighWatermark = Date(timeIntervalSince1970: 800)
        let boundaryAfterSnapshot = SyncPullCursor(
            changedAt: Date(timeIntervalSince1970: 900),
            stableID: "m-after-snapshot"
        )
        let next = IncrementalSyncCursor.next(
            previous: SyncPullCursor(changedAt: previous),
            attemptStartedAt: started,
            limit: 500,
            rowCount: 500,
            serverBoundary: boundaryAfterSnapshot,
            serverHighWatermark: serverHighWatermark
        )

        #expect(next == SyncPullCursor(changedAt: serverHighWatermark))
    }

    @Test func compoundRepeatedBoundaryDoesNotRegressOrLoop() {
        let previous = SyncPullCursor(changedAt: self.previous, stableID: "m-0500")
        let repeated = SyncPullCursor(changedAt: self.previous, stableID: "m-0500")

        let next = IncrementalSyncCursor.next(
            previous: previous,
            attemptStartedAt: started,
            limit: 500,
            rowCount: 500,
            serverBoundary: repeated
        )

        #expect(next == previous)
    }

    @Test func compoundMissingServerBoundaryOnFullPageRetainsPreviousCursor() {
        let previous = SyncPullCursor(changedAt: self.previous, stableID: "m-0001")

        let next = IncrementalSyncCursor.next(
            previous: previous,
            attemptStartedAt: started,
            limit: 500,
            rowCount: 500,
            serverBoundary: nil
        )

        #expect(next == previous)
    }

    @Test func compoundServerClockAheadCannotAdvancePastPullStart() {
        let ahead = SyncPullCursor(changedAt: Date(timeIntervalSince1970: 2_000), stableID: "m-0500")

        let next = IncrementalSyncCursor.next(
            previous: SyncPullCursor(changedAt: previous, stableID: "m-0001"),
            attemptStartedAt: started,
            limit: 500,
            rowCount: 500,
            serverBoundary: ahead
        )

        #expect(next == SyncPullCursor(changedAt: started))
    }

    @Test func cursorSetExpandsLegacyTimestampAcrossEveryEntity() {
        let set = SyncPullCursorSet(legacyTimestamp: previous)

        for entity in SyncPullEntity.allCases {
            #expect(set[entity] == SyncPullCursor(changedAt: previous))
        }
    }

    @Test func drainConsumesSaturatedPageAndFinalShortPage() async throws {
        let firstBoundary = SyncPullCursor(
            changedAt: Date(timeIntervalSince1970: 600),
            stableID: "m-0499"
        )
        let highWatermark = Date(timeIntervalSince1970: 800)
        let pages = SyncPageStub<Int>(pages: [
            SyncPullPage(rows: Array(0..<500), serverBoundary: firstBoundary, serverHighWatermark: highWatermark),
            SyncPullPage(rows: [500], serverBoundary: nil, serverHighWatermark: highWatermark),
        ])

        let result = try await SyncPageDrain.run(
            initialCursor: .initial,
            attemptStartedAt: started,
            fetch: { cursor in try await pages.fetch(cursor: cursor) }
        )

        #expect(result.rows == Array(0...500))
        #expect(result.pageCount == 2)
        #expect(result.nextCursor == SyncPullCursor(changedAt: highWatermark))
        #expect(await pages.requestedCursors() == [.initial, firstBoundary])
    }
}

private actor SyncPageStub<Row: Sendable> {
    private var pages: [SyncPullPage<Row>]
    private var cursors: [SyncPullCursor] = []

    init(pages: [SyncPullPage<Row>]) {
        self.pages = pages
    }

    func fetch(cursor: SyncPullCursor) throws -> SyncPullPage<Row> {
        cursors.append(cursor)
        guard !pages.isEmpty else { throw SyncPageDrainError.stalled }
        return pages.removeFirst()
    }

    func requestedCursors() -> [SyncPullCursor] { cursors }
}
