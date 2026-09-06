import Foundation
import Testing
@testable import AbbeyBotApp

@Suite("Desktop sync client transport")
struct AbbeyServerClientTransportTests {
    @Test func rejectsInsecureNonLoopbackBeforeBuildingCredentialedRequest() {
        for baseURL in ["http://172.16.0.10:8080", "http://example.com", "http://[::2]:8080"] {
            let client = AbbeyServerClient(
                syncServerURL: { baseURL },
                syncAPIToken: { "top-secret" }
            )
            #expect(throws: AbbeyServerClient.SyncClientError.self) {
                try client.makeRequest(path: "/api/ingest", method: "POST")
            }
        }
    }

    @Test func permitsExactLoopbacksAndHTTPS() throws {
        for baseURL in ["http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080", "https://sync.example.com"] {
            let client = AbbeyServerClient(
                syncServerURL: { baseURL },
                syncAPIToken: { "allowed-token" }
            )
            let request = try client.makeRequest(path: "/api/users", method: "GET")
            #expect(request.url != nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer allowed-token")
        }
    }

    @Test func failedRequestKeepsOriginalDestinationAcrossConfigurationChange() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopOutbox-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = PendingPushQueue(url: url)
        let state = OutboxTransportState()
        let client = AbbeyServerClient(
            syncServerURL: { state.endpoint }, syncAPIToken: { state.token }, outbox: queue,
            transport: { request in
                let count = state.record(request)
                if count == 1 {
                    // Change settings while the original A request is still in flight.
                    state.configure(endpoint: "https://b.example", token: "token-b")
                    throw URLError(.cannotConnectToHost)
                }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )

        await client.remember(guildId: "g", userId: "u", fact: "private to A")
        #expect(try queue.pendingCount() == 1)
        let persisted = try Data(contentsOf: url)
        #expect(!String(decoding: persisted, as: UTF8.self).contains("token-a"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("token-b"))
        #expect(await client.flushPendingPushes() == 0)
        #expect(state.requests.count == 1)
        #expect(try Data(contentsOf: url) == persisted)

        state.configure(endpoint: "", token: "")
        #expect(await client.flushPendingPushes() == 0)
        #expect(try Data(contentsOf: url) == persisted)
        state.configure(endpoint: "http://remote.example", token: "invalid-token")
        #expect(await client.flushPendingPushes() == 0)
        #expect(try Data(contentsOf: url) == persisted)

        state.configure(endpoint: " HTTPS://A.EXAMPLE:443/ ", token: "rotated-token-a")
        #expect(await client.flushPendingPushes() == 1)
        #expect(try queue.pendingCount() == 0)
        #expect(state.requests.map { $0.url?.host } == ["a.example", "a.example"])
        #expect(state.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer rotated-token-a")
    }

    @Test(arguments: ["//", "///"])
    func repeatedTrailingSlashesPreserveGETPOSTParityAndQueueIsolation(slashes: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopOutbox-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = PendingPushQueue(url: url)
        let endpoint = "https://a.example/base" + slashes
        let normalized = try PendingPushQueue.normalizedEndpoint(endpoint)
        #expect(normalized == endpoint)
        #expect(try PendingPushQueue.normalizedEndpoint(normalized) == normalized)
        let state = OutboxTransportState()
        state.configure(endpoint: endpoint, token: "token-a")
        let client = AbbeyServerClient(
            syncServerURL: { state.endpoint }, syncAPIToken: { state.token }, outbox: queue,
            transport: { request in
                if state.record(request) == 1 { throw URLError(.cannotConnectToHost) }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let get = try client.makeRequest(path: "/api/state/remember", method: "GET")
        #expect(get.url?.absoluteString == "https://a.example/base" + slashes + "api/state/remember")
        await client.remember(guildId: "g", userId: "u", fact: "bound to repeated slashes")
        #expect(state.requests.first?.url == get.url)
        #expect(try queue.pendingCount() == 1)
        let persisted = try Data(contentsOf: url)

        state.configure(endpoint: "https://a.example/base/", token: "token-a")
        let otherGET = try client.makeRequest(path: "/api/state/remember", method: "GET")
        #expect(otherGET.url != get.url)
        #expect(await client.flushPendingPushes() == 0)
        #expect(state.requests.count == 1)
        #expect(try Data(contentsOf: url) == persisted)

        state.configure(endpoint: endpoint, token: "token-a")
        #expect(await client.flushPendingPushes() == 1)
        #expect(state.requests.map { $0.url } == [get.url, get.url])
        #expect(try queue.pendingCount() == 0)
    }

    @Test func flushSnapshotsDestinationAndTokenForEveryRecord() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopOutbox-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = PendingPushQueue(url: url)
        for fact in ["one", "two"] {
            try queue.enqueue(path: "/api/state/remember", jsonObjectBody: ["fact": fact], endpoint: "https://a.example")
        }
        let state = OutboxTransportState()
        let client = AbbeyServerClient(
            syncServerURL: { state.endpoint }, syncAPIToken: { state.token }, outbox: queue,
            transport: { request in
                _ = state.record(request)
                state.configure(endpoint: "https://b.example", token: "token-b")
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        #expect(await client.flushPendingPushes() == 2)
        #expect(state.requests.map { $0.url?.host } == ["a.example", "a.example"])
        #expect(state.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-a", "Bearer token-a"])
        #expect(try queue.pendingCount() == 0)
    }
}

private final class OutboxTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentEndpoint = "https://a.example"
    private var currentToken = "token-a"
    private var recordedRequests: [URLRequest] = []

    var endpoint: String { lock.withLock { currentEndpoint } }
    var token: String { lock.withLock { currentToken } }
    var requests: [URLRequest] { lock.withLock { recordedRequests } }

    func configure(endpoint: String, token: String) {
        lock.withLock {
            currentEndpoint = endpoint
            currentToken = token
        }
    }

    func record(_ request: URLRequest) -> Int {
        lock.withLock {
            recordedRequests.append(request)
            return recordedRequests.count
        }
    }
}
