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
}
