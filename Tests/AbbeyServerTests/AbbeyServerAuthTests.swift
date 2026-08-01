import AbbeyServer
import Foundation
import Testing
import Vapor
import VaporTesting

/// HTTP-level tests against the actual registered routes (via `configure(_:)`), not just
/// `BotRuntime`/`Repositories` directly — this is the first coverage of `AbbeyServer`'s own
/// route wiring, including auth gating, which previously had zero test coverage at all.
/// `.serialized`: tests here mutate process-wide env vars (ABBEY_API_TOKEN, DATABASE_URL)
/// with different values per test — Swift Testing's default parallel execution would race them.
@Suite("AbbeyServer HTTP routes — auth", .serialized)
struct AbbeyServerAuthTests {
    private func withApp<T: Sendable>(
        token: String?,
        eventSubSecret: String? = nil,
        allowUnsignedEventSubForTesting: Bool = false,
        allowUnsignedSocialForTesting: Bool = false,
        _ body: @Sendable (Application) async throws -> T
    ) async throws -> T {
        unsetenv("DISCORD_BOT_TOKEN")
        unsetenv("DISCORD_DEV_GUILD_ID")
        setenv("DATABASE_URL", "sqlite://memory", 1)
        if let token {
            setenv("ABBEY_API_TOKEN", token, 1)
        } else {
            unsetenv("ABBEY_API_TOKEN")
        }
        if let eventSubSecret {
            setenv("TWITCH_EVENTSUB_SECRET", eventSubSecret, 1)
        } else {
            unsetenv("TWITCH_EVENTSUB_SECRET")
        }
        if allowUnsignedEventSubForTesting {
            setenv("ABBEY_ALLOW_UNSIGNED_TWITCH_EVENTSUB_FOR_TESTING", "1", 1)
        } else {
            unsetenv("ABBEY_ALLOW_UNSIGNED_TWITCH_EVENTSUB_FOR_TESTING")
        }
        if allowUnsignedSocialForTesting {
            setenv("ABBEY_ALLOW_UNSIGNED_SOCIAL_WEBHOOKS_FOR_TESTING", "1", 1)
        } else {
            unsetenv("ABBEY_ALLOW_UNSIGNED_SOCIAL_WEBHOOKS_FOR_TESTING")
        }
        unsetenv("ABBEY_DRY_RUN")

        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            let result = try await body(app)
            try await app.asyncShutdown()
            unsetenv("ABBEY_API_TOKEN")
            unsetenv("TWITCH_EVENTSUB_SECRET")
            unsetenv("ABBEY_ALLOW_UNSIGNED_TWITCH_EVENTSUB_FOR_TESTING")
            unsetenv("ABBEY_ALLOW_UNSIGNED_SOCIAL_WEBHOOKS_FOR_TESTING")
            unsetenv("DATABASE_URL")
            return result
        } catch {
            try? await app.asyncShutdown()
            unsetenv("ABBEY_API_TOKEN")
            unsetenv("TWITCH_EVENTSUB_SECRET")
            unsetenv("ABBEY_ALLOW_UNSIGNED_TWITCH_EVENTSUB_FOR_TESTING")
            unsetenv("ABBEY_ALLOW_UNSIGNED_SOCIAL_WEBHOOKS_FOR_TESTING")
            unsetenv("DATABASE_URL")
            throw error
        }
    }

    private func bearerHeaders(_ token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token)
        return headers
    }

    private func jsonHeaders(token: String? = nil) -> HTTPHeaders {
        var headers = token.map(bearerHeaders) ?? HTTPHeaders()
        headers.contentType = .json
        return headers
    }

    private func jsonBody(_ string: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        return buffer
    }

    @Test func getStateUserRejectsWithoutTokenWhenConfigured() async throws {
        try await withApp(token: "secret-token") { app in
            try await app.testing().test(.GET, "/api/state/user?guildId=g1&userId=u1") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func getStateUserSucceedsWithCorrectBearerToken() async throws {
        try await withApp(token: "secret-token") { app in
            try await app.testing().test(
                .GET, "/api/state/user?guildId=g1&userId=u1", headers: bearerHeaders("secret-token")
            ) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func getStateChannelRejectsWithoutTokenWhenConfigured() async throws {
        try await withApp(token: "secret-token") { app in
            try await app.testing().test(.GET, "/api/state/channel?guildId=g1&channelId=c1") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func getStateChannelSucceedsWithCorrectBearerToken() async throws {
        try await withApp(token: "secret-token") { app in
            try await app.testing().test(
                .GET, "/api/state/channel?guildId=g1&channelId=c1", headers: bearerHeaders("secret-token")
            ) { res in
                #expect(res.status == .ok)
            }
        }
    }

    /// Preserves the documented local-smoke convention: unset token means gated routes
    /// stay open. A regression here would silently lock every local/dev boot out of these.
    @Test func getStateUserStaysOpenWhenTokenUnset() async throws {
        try await withApp(token: nil) { app in
            try await app.testing().test(.GET, "/api/state/user?guildId=g1&userId=u1") { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func getStateChannelStaysOpenWhenTokenUnset() async throws {
        try await withApp(token: nil) { app in
            try await app.testing().test(.GET, "/api/state/channel?guildId=g1&channelId=c1") { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func healthRemainsPublicWhenTokenConfigured() async throws {
        try await withApp(token: "secret-token") { app in
            try await app.testing().test(.GET, "/health") { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func metricsAndStatusRejectWithoutConfiguredTokenHeader() async throws {
        try await withApp(token: "secret-token") { app in
            try await app.testing().test(.GET, "/api/metrics") { res in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(.GET, "/api/status") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func metricsAndStatusAcceptConfiguredTokenHeader() async throws {
        try await withApp(token: "secret-token") { app in
            let headers = bearerHeaders("secret-token")
            try await app.testing().test(.GET, "/api/metrics", headers: headers) { res in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, "/api/status", headers: headers) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func socialCatalogUsesConfiguredOperatorToken() async throws {
        try await withApp(token: "secret-token") { app in
            try await app.testing().test(.GET, "/api/social/catalog") { res in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(
                .GET,
                "/api/social/catalog",
                headers: bearerHeaders("secret-token")
            ) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func genericSocialWebhookFailsClosedWhenSharedTokenIsMissing() async throws {
        try await withApp(token: nil) { app in
            try await app.testing().test(
                .POST,
                "/api/social/youtube/webhook",
                headers: jsonHeaders(),
                body: jsonBody(#"{"text":"hello","channelId":"c1","author":"u1"}"#)
            ) { res in
                #expect(res.status == .serviceUnavailable)
            }
        }
    }

    @Test func genericSocialWebhookRequiresAndAcceptsConfiguredToken() async throws {
        let body = jsonBody(#"{"text":"hello","channelId":"c1","author":"u1","videoId":"m1"}"#)
        try await withApp(token: "secret-token") { app in
            try await app.testing().test(
                .POST,
                "/api/social/youtube/webhook",
                headers: jsonHeaders(),
                body: body
            ) { res in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(
                .POST,
                "/api/social/youtube/webhook",
                headers: jsonHeaders(token: "secret-token"),
                body: body
            ) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("social-accepted-youtube"))
            }
        }
    }

    @Test func genericSocialWebhookBypassIsExplicitAndTestingOnly() async throws {
        try await withApp(
            token: nil,
            allowUnsignedSocialForTesting: true
        ) { app in
            try await app.testing().test(
                .POST,
                "/api/social/youtube/webhook",
                headers: jsonHeaders(),
                body: jsonBody(#"{"text":"dry run","channelId":"c1","author":"u1"}"#)
            ) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func twitchEventSubFailsClosedWhenSecretIsMissing() async throws {
        try await withApp(token: nil) { app in
            try await app.testing().test(
                .POST,
                "/api/twitch/eventsub",
                headers: jsonHeaders(),
                body: jsonBody(#"{"subscription":{"type":"unknown","status":"enabled"}}"#)
            ) { res in
                #expect(res.status == .serviceUnavailable)
            }
        }
    }

    @Test func twitchEventSubRejectsUnsignedDeliveryWhenSecretIsConfigured() async throws {
        try await withApp(token: nil, eventSubSecret: "eventsub-secret") { app in
            try await app.testing().test(
                .POST,
                "/api/twitch/eventsub",
                headers: jsonHeaders(),
                body: jsonBody(#"{"subscription":{"type":"unknown","status":"enabled"}}"#)
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func twitchEventSubUnsignedBypassIsExplicitAndTestingOnly() async throws {
        try await withApp(
            token: nil,
            allowUnsignedEventSubForTesting: true
        ) { app in
            try await app.testing().test(
                .POST,
                "/api/twitch/eventsub",
                headers: jsonHeaders(),
                body: jsonBody(#"{"subscription":{"type":"unknown","status":"enabled"}}"#)
            ) { res in
                #expect(res.status == .ok)
            }
        }
    }
}
