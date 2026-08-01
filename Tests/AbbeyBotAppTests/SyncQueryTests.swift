import AbbeyCore
import Foundation
import Testing

@testable import AbbeyBotApp

@Suite("SyncQuery list-endpoint query items")
struct SyncQueryTests {
    @Test func limitOnlyWhenNoCursor() {
        let items = SyncQuery.listItems(limit: 250, since: nil)

        #expect(items.count == 1)
        #expect(items[0].name == "limit")
        #expect(items[0].value == "250")
    }

    @Test func clampsLimitToServerMaximum() {
        #expect(SyncQuery.listItems(limit: 5000, since: nil).first?.value == "500")
        #expect(SyncQuery.listItems(limit: 0, since: nil).first?.value == "1")
    }

    /// The server parses `?since=` as a unix-epoch Double (`Date(timeIntervalSince1970:)`),
    /// so the client must send that exact shape — not ISO-8601.
    @Test func encodesCursorAsUnixEpochSeconds() {
        let cursor = Date(timeIntervalSince1970: 1_700_000_000)
        let items = SyncQuery.listItems(limit: 100, since: cursor)

        #expect(items.count == 2)
        let since = items.first { $0.name == "since" }
        #expect(since?.value == "1700000000.0")
        #expect(Double(since?.value ?? "") == 1_700_000_000)
    }

    @Test func roundTripsThroughServerStyleParsing() {
        let cursor = Date(timeIntervalSince1970: 1_712_345_678)
        let items = SyncQuery.listItems(limit: 100, since: cursor)

        // Mirrors AbbeyServer's sinceParam(_:): query["since"] as Double -> Date.
        let raw = Double(items.first { $0.name == "since" }?.value ?? "")
        let parsed = raw.map { Date(timeIntervalSince1970: $0) }

        #expect(parsed == cursor)
    }

    @Test func encodesCompoundStableIDAfterTimestamp() {
        let cursor = SyncPullCursor(
            changedAt: Date(timeIntervalSince1970: 1_712_345_678.25),
            stableID: "guild:user"
        )
        let items = SyncQuery.listItems(limit: 500, cursor: cursor)

        #expect(items.map(\.name) == ["limit", "since", "after"])
        #expect(items.first { $0.name == "since" }?.value == "1712345678.25")
        #expect(items.first { $0.name == "after" }?.value == "guild:user")
    }
}
