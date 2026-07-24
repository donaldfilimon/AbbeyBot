import Foundation
import Testing
@testable import AbbeyBotApp

@Suite("PendingPushQueue")
struct PendingPushQueueTests {
    private func makeQueue() -> (PendingPushQueue, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingPushQueueTests-\(UUID().uuidString).jsonl")
        return (PendingPushQueue(url: url), url)
    }

    @Test func enqueueThenDrainReplaysInOrderAndEmptiesOnSuccess() async throws {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        try queue.enqueue(path: "/api/ingest", jsonObjectBody: ["content": "hello"])
        try queue.enqueue(path: "/api/state/remember", jsonObjectBody: ["fact": "likes tea"])

        var sentPaths: [String] = []
        let flushed = try await queue.drain { path, _ in
            sentPaths.append(path)
            return true
        }

        #expect(flushed == 2)
        #expect(sentPaths == ["/api/ingest", "/api/state/remember"])
        #expect(try queue.pendingCount() == 0)
    }

    @Test func drainKeepsEntriesThatStillFail() async throws {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        try queue.enqueue(path: "/api/ingest", jsonObjectBody: ["content": "will succeed"])
        try queue.enqueue(path: "/api/ingest", jsonObjectBody: ["content": "will fail"])

        let flushed = try await queue.drain { _, bodyData in
            let text = String(decoding: bodyData, as: UTF8.self)
            return !text.contains("will fail")
        }

        #expect(flushed == 1)
        #expect(try queue.pendingCount() == 1)

        // A second drain with everything succeeding clears the retained entry.
        let secondFlush = try await queue.drain { _, _ in true }
        #expect(secondFlush == 1)
        #expect(try queue.pendingCount() == 0)
    }

    @Test func pendingCountReflectsQueuedEntries() throws {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try queue.pendingCount() == 0)
        try queue.enqueue(path: "/api/ingest", jsonObjectBody: ["content": "one"])
        #expect(try queue.pendingCount() == 1)
        try queue.enqueue(path: "/api/ingest", jsonObjectBody: ["content": "two"])
        #expect(try queue.pendingCount() == 2)
    }
}
