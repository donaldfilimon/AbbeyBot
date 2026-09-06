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

        try queue.enqueue(path: "/api/ingest", jsonObjectBody: ["content": "hello"], endpoint: "https://a.example")
        try queue.enqueue(path: "/api/state/remember", jsonObjectBody: ["fact": "likes tea"], endpoint: "https://a.example")

        var sentPaths: [String] = []
        let flushed = try await queue.drain(endpoint: "https://a.example") { path, _ in
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

        try queue.enqueue(path: "/api/ingest", jsonObjectBody: ["content": "will succeed"], endpoint: "https://a.example")
        try queue.enqueue(path: "/api/ingest", jsonObjectBody: ["content": "will fail"], endpoint: "https://a.example")

        let flushed = try await queue.drain(endpoint: "https://a.example") { _, bodyData in
            let text = String(decoding: bodyData, as: UTF8.self)
            return !text.contains("will fail")
        }

        #expect(flushed == 1)
        #expect(try queue.pendingCount() == 1)

        // A second drain with everything succeeding clears the retained entry.
        let secondFlush = try await queue.drain(endpoint: "https://a.example") { _, _ in true }
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

    @Test func legacyBytesRemainQuarantinedWhenBoundRecordDrains() async throws {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = Data("{ \"path\":\"/api/ingest\", \"bodyJSON\":\"e30=\", \"enqueuedAt\":\"2026-09-06T00:00:00Z\" }\r\n".utf8)
        try legacy.write(to: url)
        try queue.enqueue(path: "/api/state/remember", jsonObjectBody: ["fact": "bound"], endpoint: "https://a.example")
        var paths: [String] = []
        #expect(try await queue.drain(endpoint: "https://a.example") { path, _ in
            paths.append(path)
            return true
        } == 1)
        #expect(paths == ["/api/state/remember"])
        #expect(try Data(contentsOf: url) == legacy)
        #expect(try queue.pendingCount() == 1)
        #expect(try await queue.drain { _, _ in
            Issue.record("Destination-less drain must not send")
            return true
        } == 0)
        #expect(try Data(contentsOf: url) == legacy)
    }

    @Test func endpointIdentityPreservesBasePathAndRejectsCredentials() throws {
        #expect(try PendingPushQueue.normalizedEndpoint(" HTTPS://A.EXAMPLE:443/base/ ") == "https://a.example/base")
        for endpoint in ["https://user:secret@a.example", "https://a.example?token=secret", "https://a.example#secret"] {
            #expect(throws: (any Error).self) {
                try PendingPushQueue.normalizedEndpoint(endpoint)
            }
        }
    }

    @Test func enqueueDuringAwaitedDrainIsPreserved() async throws {
        let (queue, url) = makeQueue()
        defer { try? FileManager.default.removeItem(at: url) }

        try queue.enqueue(path: "/api/ingest", jsonObjectBody: ["content": "snapshot"], endpoint: "https://a.example")
        let concurrentWriter = PendingPushQueue(url: url)
        let gate = DrainGate()

        let draining = Task {
            try await queue.drain(endpoint: "https://a.example") { _, _ in
                await gate.markSendStartedAndWaitForRelease()
                return true
            }
        }

        await gate.waitUntilSendStarted()
        try concurrentWriter.enqueue(
            path: "/api/state/remember",
            jsonObjectBody: ["fact": "arrived during drain"],
            endpoint: "https://a.example"
        )
        await gate.releaseSend()

        #expect(try await draining.value == 1)
        #expect(try queue.pendingCount() == 1)

        var replayedPaths: [String] = []
        #expect(try await queue.drain(endpoint: "https://a.example") { path, _ in
            replayedPaths.append(path)
            return true
        } == 1)
        #expect(replayedPaths == ["/api/state/remember"])
        #expect(try queue.pendingCount() == 0)
    }
}

private actor DrainGate {
    private var sendStarted = false
    private var sendReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markSendStartedAndWaitForRelease() async {
        sendStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        guard !sendReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilSendStarted() async {
        guard !sendStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseSend() {
        sendReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
