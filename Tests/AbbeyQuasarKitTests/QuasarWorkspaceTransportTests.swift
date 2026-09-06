import Foundation
import Testing
@testable import AbbeyQuasarKit

struct QuasarWorkspaceTransportTests {
    @Test func acceptsHTTPSAndExactLoopbackOnly() throws {
        for endpoint in ["https://api.xfoss.dev", "http://127.0.0.1:8080", "http://[::1]:8080", "http://localhost:8080"] {
            _ = try QuasarEndpointPolicy.validate(endpoint)
        }
        for endpoint in ["http://api.xfoss.dev", "http://127.1", "http://localhost.evil.test", "https://user:secret@api.xfoss.dev", "https://api.xfoss.dev/path", "https://api.xfoss.dev?token=secret", "file:///tmp/api"] {
            #expect(throws: QuasarWorkspaceError.self) { try QuasarEndpointPolicy.validate(endpoint) }
        }
    }

    @Test func rejectsRedirectsOutsideOriginalOrigin() throws {
        let endpoint = try QuasarEndpointPolicy.validate("https://api.xfoss.dev")
        #expect(QuasarEndpointPolicy.sameOrigin(endpoint, URL(string: "https://api.xfoss.dev/api/sites")!))
        #expect(!QuasarEndpointPolicy.sameOrigin(endpoint, URL(string: "https://other.xfoss.dev/api/sites")!))
        #expect(!QuasarEndpointPolicy.sameOrigin(endpoint, URL(string: "http://api.xfoss.dev/api/sites")!))
        #expect(!QuasarEndpointPolicy.sameOrigin(endpoint, URL(string: "https://api.xfoss.dev:8443/api/sites")!))
    }

    @Test func transportMessagesNeverContainServerBodiesOrCredentials() {
        #expect(QuasarWorkspaceError.connection.localizedDescription == "Unable to reach the Quasar service. Previously loaded data has been retained.")
        #expect(QuasarWorkspaceError.uncertainOutcome.localizedDescription.contains("Do not repeat"))
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized)
struct QuasarHTTPWorkspaceTests {
    private func client() throws -> HTTPQuasarWorkspaceClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QuasarStubProtocol.self]
        return try .init(endpoint: "https://api.example.test", token: "dedicated-secret", configuration: config)
    }

    @Test func mutationConnectionLossRemainsUncertainAndIsNotRetried() async throws {
        QuasarStubProtocol.state.withLock { $0 = .init(status: nil, body: "secret echoed body") }
        let client = try client()
        await #expect(throws: QuasarWorkspaceError.uncertainOutcome) {
            _ = try await client.create(name: "Name", prompt: "Prompt")
        }
        #expect(QuasarStubProtocol.state.withLock { $0.requests.count } == 1)
    }

    @Test func rejectsCapabilityMismatchAndUsesDedicatedToken() async throws {
        QuasarStubProtocol.state.withLock { $0 = .init(status: 200, body: #"{"apiVersion":2,"serviceID":"other","discordApproval":false,"contentReview":true,"durableHistory":true,"privatePreviews":false}"#) }
        let client = try client()
        await #expect(throws: QuasarWorkspaceError.incompatibleService) { _ = try await client.capabilities() }
        let sent = try #require(QuasarStubProtocol.state.withLock { $0.requests.first })
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer dedicated-secret")
        #expect(sent.url?.path == "/api/quasar/capabilities")
    }

    @Test func rejectsServerErrorWithoutLeakingItsBody() async throws {
        QuasarStubProtocol.state.withLock { $0 = .init(status: 503, body: "provider-secret password=hidden") }
        let client = try client()
        do { _ = try await client.listSites(); Issue.record("Expected rejection") }
        catch { #expect(!error.localizedDescription.contains("hidden")); #expect(!error.localizedDescription.contains("provider-secret")) }
    }
}

import Synchronization
private final class QuasarStubProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var status: Int?
        var body: String
        var requests: [URLRequest] = []
    }
    static let state = Mutex(State(status: 200, body: "{}"))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.withLock { state in state.requests.append(request); return state }
        guard let status = response.status else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
