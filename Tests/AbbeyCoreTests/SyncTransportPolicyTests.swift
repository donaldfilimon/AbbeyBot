import Foundation
import Testing
@testable import AbbeyCore

@Suite("Sync transport policy")
struct SyncTransportPolicyTests {
    @Test func permitsExactHTTPLoopbacksAndHTTPSHosts() throws {
        let permitted = [
            "http://localhost:8080",
            "HTTP://LOCALHOST:8080/base",
            "http://127.0.0.1:8080",
            "http://[::1]:8080",
            "https://example.com",
            "https://192.168.1.25:8443/base",
            "https://[2001:db8::1]/sync",
        ]

        for rawURL in permitted {
            let url = try SyncTransportPolicy.validate(baseURL: rawURL)
            #expect(url.scheme?.lowercased() == rawURL.prefix(5).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":/")))
        }
    }

    @Test func rejectsPlainHTTPOutsideExactLoopbackAndMalformedSchemes() {
        let rejected = [
            "http://192.168.1.25:8080",
            "http://example.com",
            "http://localhost.example.com",
            "http://127.0.0.2",
            "http://[::2]:8080",
            "ftp://localhost/resource",
            "localhost:8080",
            "https:///missing-host",
            "not a url",
        ]

        for rawURL in rejected {
            #expect(throws: SyncTransportPolicy.PolicyError.self) {
                try SyncTransportPolicy.validate(baseURL: rawURL)
            }
        }
    }

    @Test func makeRequestJoinsPathQueryAndAttachesBearerToken() throws {
        let request = try SyncTransportPolicy.makeRequest(
            baseURL: "https://example.com/base/",
            path: "api/users",
            method: "GET",
            queryItems: [URLQueryItem(name: "limit", value: "500")],
            bearerToken: "secret"
        )

        #expect(request.url?.absoluteString == "https://example.com/base/api/users?limit=500")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func makeRequestOmitsAuthorizationForNilOrEmptyToken() throws {
        for token in [nil, ""] as [String?] {
            let request = try SyncTransportPolicy.makeRequest(
                baseURL: "http://localhost:8080",
                path: "/api/ingest",
                method: "POST",
                bearerToken: token
            )
            #expect(request.url?.absoluteString == "http://localhost:8080/api/ingest")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test func makeRequestNeverBuildsARequestForRejectedTransports() {
        for rawURL in ["http://example.com", "ftp://localhost", "not a url"] {
            #expect(throws: SyncTransportPolicy.PolicyError.self) {
                try SyncTransportPolicy.makeRequest(
                    baseURL: rawURL,
                    path: "/api/users",
                    method: "GET",
                    bearerToken: "secret"
                )
            }
        }
    }

    @Test func appConfigUsesTheSharedPolicy() throws {
        let scratch = try ScratchDefaults("AbbeyCoreTests.syncTransport")
        defer { scratch.remove() }
        let defaults = scratch.defaults
        let config = AppConfig(defaults: defaults, environment: [:], tokens: InMemoryTokenStore())

        for allowed in ["http://localhost:8080", "http://127.0.0.1", "http://[::1]:8080", "https://example.com"] {
            config.syncServerURL = allowed
            try config.validateForStartup(scope: .headless)
        }

        for rejected in ["http://10.0.0.5:8080", "http://example.com", "http://[::2]:8080", "file://localhost/tmp/sync"] {
            config.syncServerURL = rejected
            #expect(throws: AppConfigValidationError.self) {
                try config.validateForStartup(scope: .headless)
            }
        }
    }
}
