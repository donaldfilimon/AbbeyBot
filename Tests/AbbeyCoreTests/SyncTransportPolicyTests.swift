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

    @Test func appConfigUsesTheSharedPolicy() throws {
        let suite = "AbbeyCoreTests.syncTransport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = AppConfig(defaults: defaults, environment: [:])

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
