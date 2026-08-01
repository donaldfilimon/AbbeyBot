import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AbbeyServerKit

@Suite("Server sync client transport")
struct ServerSyncClientTransportTests {
    @Test func rejectsInsecureNonLoopbackBeforeBuildingCredentialedRequest() {
        for baseURL in ["http://192.168.1.50:8080", "http://example.com", "http://[::2]:8080"] {
            let client = ServerSyncClient(baseURL: baseURL, apiToken: "top-secret")
            #expect(throws: ServerSyncClient.ClientError.self) {
                try client.makeRequest(path: "/api/users", method: "GET")
            }
        }
    }

    @Test func permitsIPv6LoopbackAndHTTPSWithBearerToken() throws {
        let loopback = ServerSyncClient(baseURL: "http://[::1]:8080", apiToken: "local-token")
        let loopbackRequest = try loopback.makeRequest(path: "/api/users", method: "GET")
        #expect(loopbackRequest.url?.host == "[::1]" || loopbackRequest.url?.host == "::1")
        #expect(loopbackRequest.value(forHTTPHeaderField: "Authorization") == "Bearer local-token")

        let secure = ServerSyncClient(baseURL: "https://sync.example.com/base", apiToken: "remote-token")
        let secureRequest = try secure.makeRequest(
            path: "/api/messages",
            method: "GET",
            queryItems: [URLQueryItem(name: "limit", value: "25")]
        )
        #expect(secureRequest.url?.absoluteString == "https://sync.example.com/base/api/messages?limit=25")
        #expect(secureRequest.value(forHTTPHeaderField: "Authorization") == "Bearer remote-token")
    }
}
