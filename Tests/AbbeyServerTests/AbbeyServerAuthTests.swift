import AbbeyCore
import AbbeyServer
import AbbeyServerKit
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
    private func withApp(
        token: String?,
        eventSubSecret: String? = nil,
        allowUnsignedEventSubForTesting: Bool = false,
        allowUnsignedSocialForTesting: Bool = false,
        _ body: @Sendable (Application) async throws -> Void
    ) async throws {
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
            try await body(app)
            try await app.asyncShutdown()
            unsetenv("ABBEY_API_TOKEN")
            unsetenv("TWITCH_EVENTSUB_SECRET")
            unsetenv("ABBEY_ALLOW_UNSIGNED_TWITCH_EVENTSUB_FOR_TESTING")
            unsetenv("ABBEY_ALLOW_UNSIGNED_SOCIAL_WEBHOOKS_FOR_TESTING")
            unsetenv("DATABASE_URL")
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

    @Test func operatorLeafFollowsConfiguredTokenPolicy() async throws {
        try await withApp(token: "secret-token") { app in
            try await app.testing().test(.GET, "/") { res in
                #expect(res.status == .unauthorized)
            }
            try await app.testing().test(
                .GET,
                "/",
                headers: bearerHeaders("secret-token")
            ) { res in
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

    @Test func messageListPublishesExactCompoundCursorWithoutWrappingArrayBody() async throws {
        try await withApp(token: nil) { app in
            let stamp = Date(timeIntervalSince1970: 1_700_000_000.25)
            let row = GuildMessage(
                discordMessageId: "m-cursor-1",
                channelId: "c1",
                guildId: "g1",
                authorId: "u1",
                content: "cursor probe"
            )
            try await row.create(on: app.db)
            row.createdAt = stamp
            try await row.save(on: app.db)

            try await app.testing().test(
                .GET,
                "/api/messages?limit=1&since=0"
            ) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.first == "[")
                #expect(res.headers.first(name: SyncPullCursorWire.idHeader) == "m-cursor-1")
                let rawTime = res.headers.first(name: SyncPullCursorWire.timeHeader)
                #expect(Double(rawTime ?? "") == stamp.timeIntervalSince1970)
                let highWatermark = res.headers.first(name: SyncPullCursorWire.highWatermarkHeader)
                    .flatMap(Double.init)
                #expect(highWatermark != nil)
                #expect(highWatermark! >= stamp.timeIntervalSince1970)
            }

            let encodedID = "m-cursor-1".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            try await app.testing().test(
                .GET,
                "/api/messages?limit=1&since=\(stamp.timeIntervalSince1970)&after=\(encodedID)"
            ) { res in
                #expect(res.status == .ok)
                #expect(res.body.string == "[]")
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
                #expect(res.body.string.contains("social-ingested-youtube"))
                #expect(res.body.string.contains("\"duplicate\":false"))
            }
            try await app.testing().test(
                .POST,
                "/api/social/youtube/webhook",
                headers: jsonHeaders(token: "secret-token"),
                body: body
            ) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("\"duplicate\":true"))
                #expect(res.body.string.contains("\"handled\":false"))
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

    private func notificationHeaders(messageId: String) -> HTTPHeaders {
        var headers = jsonHeaders()
        headers.replaceOrAdd(name: "Twitch-Eventsub-Message-Type", value: "notification")
        headers.replaceOrAdd(name: "Twitch-Eventsub-Message-Id", value: messageId)
        return headers
    }

    /// Drives the route's outcome dispatch end-to-end and pins the ack body, which is the only
    /// externally visible contract Twitch sees.
    @Test func twitchEventSubStreamOnlineAcksAsHandled() async throws {
        try await withApp(token: nil, allowUnsignedEventSubForTesting: true) { app in
            try await app.testing().test(
                .POST,
                "/api/twitch/eventsub",
                headers: notificationHeaders(messageId: "msg-stream-online-1"),
                body: jsonBody(#"""
                {"subscription":{"type":"stream.online","status":"enabled"},
                 "event":{"broadcaster_user_login":"somechannel"}}
                """#)
            ) { res in
                #expect(res.status == .ok)
                let ack = try JSONDecoder().decode(AckProbe.self, from: Data(res.body.readableBytesView))
                #expect(ack.ok == true)
                #expect(ack.handled == true)
                #expect(ack.duplicate == false)
                #expect(ack.outcome == "stream-online")
            }
        }
    }

    /// A notification we understand but deliberately do not act on must ack as *not* handled and
    /// *not* duplicate — `duplicate: true` is reserved for genuine delivery replays.
    @Test func twitchEventSubUnactedNotificationIsAcknowledgedNotDuplicate() async throws {
        try await withApp(token: nil, allowUnsignedEventSubForTesting: true) { app in
            try await app.testing().test(
                .POST,
                "/api/twitch/eventsub",
                headers: notificationHeaders(messageId: "msg-unacted-1"),
                body: jsonBody(#"{"subscription":{"type":"channel.raid","status":"enabled"}}"#)
            ) { res in
                #expect(res.status == .ok)
                let ack = try JSONDecoder().decode(AckProbe.self, from: Data(res.body.readableBytesView))
                #expect(ack.handled == false)
                #expect(ack.duplicate == false)
                #expect(ack.outcome == "notification")
            }
        }
    }

    /// Replaying the same delivery id is the one case that may report `duplicate: true`.
    @Test func twitchEventSubReplayedDeliveryAcksAsDuplicate() async throws {
        try await withApp(token: nil, allowUnsignedEventSubForTesting: true) { app in
            let headers = notificationHeaders(messageId: "msg-replay-1")
            let body = #"""
            {"subscription":{"type":"stream.online","status":"enabled"},
             "event":{"broadcaster_user_login":"somechannel"}}
            """#
            try await app.testing().test(
                .POST, "/api/twitch/eventsub", headers: headers, body: jsonBody(body)
            ) { res in
                #expect(res.status == .ok)
            }
            try await app.testing().test(
                .POST, "/api/twitch/eventsub", headers: headers, body: jsonBody(body)
            ) { res in
                #expect(res.status == .ok)
                let ack = try JSONDecoder().decode(AckProbe.self, from: Data(res.body.readableBytesView))
                #expect(ack.handled == false)
                #expect(ack.duplicate == true)
                #expect(ack.outcome == "duplicate")
            }
        }
    }
}

/// Mirrors the route's ack body so tests assert the wire shape rather than an internal type.
private struct AckProbe: Decodable {
    var ok: Bool
    var handled: Bool
    var duplicate: Bool?
    var outcome: String?
}
