import AbbeyCore
@testable import AbbeyServer
import AbbeyQuasarKit
import AbbeyServerKit
import Fluent
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
        environment: Environment = .testing,
        dryRun: Bool = false,
        quasarToken: String? = nil,
        eventSubSecret: String? = nil,
        allowUnsignedEventSubForTesting: Bool = false,
        allowUnsignedSocialForTesting: Bool = false,
        _ body: @Sendable (Application) async throws -> Void
    ) async throws {
        let quasarHome = FileManager.default.temporaryDirectory.appendingPathComponent("abbey-server-test-quasar-\(UUID().uuidString)")
        setenv("ABBEY_QUASAR_HOME", quasarHome.path, 1)
        if let quasarToken { setenv("ABBEY_QUASAR_API_TOKEN", quasarToken, 1) }
        else { unsetenv("ABBEY_QUASAR_API_TOKEN") }
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
        if dryRun {
            setenv("ABBEY_DRY_RUN", "1", 1)
        } else {
            unsetenv("ABBEY_DRY_RUN")
        }

        let app = try await Application.make(environment)
        do {
            try await configure(app)
            try await body(app)
            try await app.asyncShutdown()
            unsetenv("ABBEY_API_TOKEN")
            unsetenv("TWITCH_EVENTSUB_SECRET")
            unsetenv("ABBEY_ALLOW_UNSIGNED_TWITCH_EVENTSUB_FOR_TESTING")
            unsetenv("ABBEY_ALLOW_UNSIGNED_SOCIAL_WEBHOOKS_FOR_TESTING")
            unsetenv("ABBEY_DRY_RUN")
            unsetenv("DATABASE_URL")
            unsetenv("ABBEY_QUASAR_HOME")
            unsetenv("ABBEY_QUASAR_API_TOKEN")
            try? FileManager.default.removeItem(at: quasarHome)
        } catch {
            try? await app.asyncShutdown()
            unsetenv("ABBEY_API_TOKEN")
            unsetenv("TWITCH_EVENTSUB_SECRET")
            unsetenv("ABBEY_ALLOW_UNSIGNED_TWITCH_EVENTSUB_FOR_TESTING")
            unsetenv("ABBEY_ALLOW_UNSIGNED_SOCIAL_WEBHOOKS_FOR_TESTING")
            unsetenv("ABBEY_DRY_RUN")
            unsetenv("DATABASE_URL")
            unsetenv("ABBEY_QUASAR_HOME")
            unsetenv("ABBEY_QUASAR_API_TOKEN")
            try? FileManager.default.removeItem(at: quasarHome)
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

    @Test func signedKnowledgeSearchRequiresOperatorAuthAndReturnsCitations() async throws {
        try await withApp(token: "knowledge-token") { app in
            try await app.testing().test(.GET, "/api/knowledge/search?q=authorization") { response in
                #expect(response.status == .unauthorized)
            }
            try await app.testing().test(
                .GET,
                "/api/knowledge/search?q=authorization&limit=2",
                headers: bearerHeaders("knowledge-token")
            ) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("sourceRevision"))
                #expect(body.contains("contentDigest"))
                #expect(!body.contains("private prompt"))
            }
        }
    }

    @Test func quasarWorkspaceAdditionsUseDedicatedAuthAndStableCapabilities() async throws {
        try await withApp(token: "operator-token", dryRun: true, quasarToken: "quasar-owner-token") { app in
            for path in ["/api/quasar/capabilities", "/api/quasar/proposals", "/api/sites/archives", "/api/sites/missing/history", "/api/sites/missing/plan/review"] {
                try await app.testing().test(.GET, path, headers: bearerHeaders("operator-token")) { response in
                    #expect(response.status == .unauthorized)
                }
            }
            let service = try await app.quasarServiceProvider.value()
            let expectedID = try await service.serviceIdentity()
            try await app.testing().test(.GET, "/api/quasar/capabilities", headers: bearerHeaders("quasar-owner-token")) { response in
                #expect(response.status == .ok)
                let caps = try JSONDecoder().decode(QuasarCapabilities.self, from: Data(response.body.readableBytesView))
                #expect(caps.apiVersion == 1)
                #expect(caps.serviceID == expectedID)
                #expect(caps.discordApproval)
                #expect(caps.contentReview && caps.durableHistory)
                #expect(response.headers.first(name: .cacheControl) == "no-store")
            }
            try await app.testing().test(.GET, "/api/sites/archives", headers: bearerHeaders("quasar-owner-token")) { response in
                #expect(response.status == .ok)
            }
            // Internal routes do not accept the operator token.
            try await app.testing().test(.GET, "/internal/quasar/preview/authorize", headers: bearerHeaders("quasar-owner-token")) { response in
                #expect(response.status == .notFound || response.status == .unauthorized)
            }
        }
    }

    @Test func quasarProposalApprovalIgnoresCallerPermissionClaims() async throws {
        try await withApp(token: "operator-token", dryRun: true, quasarToken: "quasar-owner-token") { app in
            let service = try await app.quasarServiceProvider.value()
            let facts = QuasarAuthorizationFacts.current(guildID: "test-guild", initiatorID: "test-user",
                discordPermissionAllowed: true, environment: ["DISCORD_OPERATOR_USER_IDS": "test-user",
                    "ABBEY_QUASAR_GUILD_IDS": "test-guild", "ABBEY_QUASAR_GUILD_BUDGET": "2"])
            _ = await service.handleDiscord(.init(action: .create, name: "Proposal", prompt: "test",
                initiatorID: "test-user", guildID: "test-guild", managerAuthorized: true), facts: facts)
            let proposal = try #require(await service.pendingDiscordProposals().first)
            var headers = bearerHeaders("quasar-owner-token")
            headers.replaceOrAdd(name: .contentType, value: "application/json")
            let body = "{\"digest\":\"\(proposal.digest)\",\"discordPermissionAllowed\":true,\"ownerAllowed\":true,\"guildOptedIn\":true,\"quiet\":false,\"remainingBudget\":999}"
            try await app.testing().test(.POST, "/api/quasar/proposals/\(proposal.id)/approve", headers: headers, body: jsonBody(body)) { response in
                // No connected Discord runtime means fresh authorization fails closed.
                #expect(response.status == .forbidden || response.status == .conflict)
            }
            #expect(await service.listSites().isEmpty)
        }
    }

    @Test func quasarAPIRequiresDedicatedTokenAndRejectsUnallowlistedOrigins() async throws {
        try await withApp(token: "operator-token", quasarToken: "quasar-owner-token") { app in
            try await app.testing().test(.GET, "/api/sites") { response in
                #expect(response.status == .unauthorized)
            }
            var allowed = bearerHeaders("quasar-owner-token")
            allowed.replaceOrAdd(name: .origin, value: "http://localhost:4710")
            try await app.testing().test(.GET, "/api/sites", headers: allowed) { response in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: .accessControlAllowOrigin) == "http://localhost:4710")
            }
            var forbidden = bearerHeaders("quasar-owner-token")
            forbidden.replaceOrAdd(name: .origin, value: "https://attacker.example")
            try await app.testing().test(.GET, "/api/sites", headers: forbidden) { response in
                #expect(response.status == .forbidden)
                #expect(response.headers.first(name: .accessControlAllowOrigin) == nil)
            }

            var preflight = HTTPHeaders()
            preflight.replaceOrAdd(name: .origin, value: "http://localhost:4710")
            preflight.replaceOrAdd(name: .accessControlRequestMethod, value: "POST")
            preflight.replaceOrAdd(name: .accessControlRequestHeaders, value: "authorization, content-type")
            try await app.testing().test(.OPTIONS, "/api/sites/create", headers: preflight) { response in
                #expect(response.status == .noContent)
                #expect(response.headers.first(name: .accessControlAllowOrigin) == "http://localhost:4710")
                #expect(response.headers.first(name: .accessControlAllowHeaders)?.contains("Authorization") == true)
            }
        }
    }

    @Test func fullServerQuasarRequiresDedicatedTokenEvenFromLoopback() async throws {
        try await withApp(token: "operator-token", quasarToken: nil) { app in
            // Exercise a real TCP request. The in-memory tester has no remote
            // address, so it cannot reproduce the reverse-proxy boundary where
            // a full server sees a loopback peer even though that peer may be
            // forwarding requests from elsewhere.
            try await app.testing(method: .running(hostname: "127.0.0.1", port: 0))
                .test(.GET, "/api/sites") { response in
                    #expect(response.status == .serviceUnavailable)
                }
        }
    }

    @Test func quasarServePolicyNormalizesEveryVaporAddressAlias() throws {
        let loopback = try QuasarServePolicy.prepare(
            arguments: ["--hostname=localhost", "-p4701", "--log", "debug"],
            environment: [:]
        )
        #expect(loopback.hostname == "localhost")
        #expect(loopback.port == 4_701)
        #expect(loopback.allowsTokenlessLoopback)
        #expect(loopback.vaporArguments == [
            "--log", "debug", "--hostname", "localhost", "--port", "4701",
        ])

        for arguments in [
            ["--hostname=0.0.0.0"],
            ["-H0.0.0.0"],
            ["--bind", "0.0.0.0:4700"],
            ["-b[::]:4700"],
        ] {
            #expect(throws: QuasarServePolicyError.nonLoopbackPolicyIncomplete) {
                _ = try QuasarServePolicy.prepare(arguments: arguments, environment: [:])
            }
        }
        #expect(throws: QuasarServePolicyError.unixSocketUnsupported) {
            _ = try QuasarServePolicy.prepare(
                arguments: ["--unix-socket=/tmp/quasar.sock"],
                environment: [:]
            )
        }
        #expect(throws: QuasarServePolicyError.missingOptionValue("--hostname")) {
            _ = try QuasarServePolicy.prepare(
                arguments: ["--hostname", "--port", "4700"],
                environment: [:]
            )
        }
        #expect(throws: QuasarServePolicyError.invalidHostname("--port")) {
            _ = try QuasarServePolicy.prepare(
                arguments: ["--hostname=--port"],
                environment: [:]
            )
        }

        let remote = try QuasarServePolicy.prepare(
            arguments: ["--bind=0.0.0.0:4800"],
            environment: [
                "ABBEY_QUASAR_ALLOW_NON_LOOPBACK": "1",
                "ABBEY_QUASAR_API_TOKEN": "owner-token",
                "ABBEY_QUASAR_ALLOWED_ORIGINS": "https://console.example",
            ]
        )
        #expect(remote.hostname == "0.0.0.0")
        #expect(remote.port == 4_800)
        #expect(!remote.allowsTokenlessLoopback)
        #expect(remote.allowedOrigins == ["https://console.example"])
        #expect(!QuasarServePolicy.isValidExactHTTPSOrigin("https://user@example.com"))
        #expect(!QuasarServePolicy.isValidExactHTTPSOrigin("https://example.com/path"))
        #expect(!QuasarServePolicy.isValidExactHTTPSOrigin("https://*.example.com"))
        #expect(!QuasarServePolicy.isValidExactHTTPSOrigin("http://example.com"))
    }

    @Test func quasarOnlyConfigurationMountsNoBotDatabaseOrGenericRoutes() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "abbey-quasar-only-\(UUID().uuidString)"
        )
        setenv("ABBEY_QUASAR_HOME", home.path, 1)
        setenv("ABBEY_QUASAR_API_TOKEN", "quasar-only-token", 1)
        unsetenv("ABBEY_QUASAR_ALLOWED_ORIGINS")
        let app = try await Application.make(.testing)
        do {
            try await configureQuasarOnly(app, allowsTokenlessLoopback: true)
            #expect(app.routes.all.contains { $0.description == "GET /api/sites" })
            #expect(!app.routes.all.contains { $0.description == "GET /health" })
            #expect(!app.routes.all.contains { $0.description == "GET /api/status" })
            try await app.testing().test(
                .GET,
                "/api/sites",
                headers: bearerHeaders("quasar-only-token")
            ) { response in
                #expect(response.status == .ok)
            }
            try await app.testing().test(.GET, "/api/quasar/capabilities", headers: bearerHeaders("quasar-only-token")) { response in
                #expect(response.status == .ok)
                let caps = try JSONDecoder().decode(QuasarCapabilities.self, from: Data(response.body.readableBytesView))
                #expect(!caps.discordApproval)
            }
            try await app.testing().test(.GET, "/health") { response in
                #expect(response.status == .notFound)
            }
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            unsetenv("ABBEY_QUASAR_HOME")
            unsetenv("ABBEY_QUASAR_API_TOKEN")
            try? FileManager.default.removeItem(at: home)
            throw error
        }
        unsetenv("ABBEY_QUASAR_HOME")
        unsetenv("ABBEY_QUASAR_API_TOKEN")
        try? FileManager.default.removeItem(at: home)
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

    @Test func protectedAPIRoutesFailClosedWhenTokenUnset() async throws {
        try await withApp(token: nil) { app in
            let getPaths = [
                "/",
                "/api/status",
                "/api/users?limit=1",
                "/api/state/user?guildId=g1&userId=u1",
                "/api/sync-status",
                "/api/social/catalog",
            ]
            for path in getPaths {
                try await app.testing().test(.GET, path) { res in
                    #expect(res.status == .serviceUnavailable, "GET \(path) returned \(res.status)")
                }
            }

            let postRequests = [
                (
                    "/api/ingest",
                    #"{"content":"auth probe","channelId":"c1","guildId":"g1","authorId":"u1"}"#
                ),
                (
                    "/api/state/remember",
                    #"{"guildId":"g1","userId":"u1","fact":"auth probe"}"#
                ),
                (
                    "/api/state/sync-status",
                    #"{"pendingPushCount":0}"#
                ),
            ]
            for (path, body) in postRequests {
                try await app.testing().test(
                    .POST,
                    path,
                    headers: jsonHeaders(),
                    body: jsonBody(body)
                ) { res in
                    #expect(res.status == .serviceUnavailable, "POST \(path) returned \(res.status)")
                }
            }
        }
    }

    @Test func protectedAPIRoutesTreatBlankConfiguredTokenAsMisconfiguration() async throws {
        try await withApp(token: " \t\n ") { app in
            try await app.testing().test(.GET, "/api/status") { res in
                #expect(res.status == .serviceUnavailable)
            }
        }
    }

    @Test func everyAPIRegistrationExceptNativeSignedWebhookFailsClosedWithoutOperatorToken() async throws {
        try await withApp(token: nil) { app in
            let apiRoutes = app.routes.all.filter { $0.path.first == .constant("api") }
            #expect(!apiRoutes.isEmpty)

            let nativeSignedWebhookRoutes: Set<String> = ["POST /api/twitch/eventsub"]
            for route in apiRoutes where !nativeSignedWebhookRoutes.contains(route.description) {
                let concretePath = route.path.map { component in
                    switch component {
                    case .constant(let value): value
                    case .parameter("platform"): "youtube"
                    case .parameter, .anything, .catchall: "auth-probe"
                    }
                }.joined(separator: "/")

                try await app.testing().test(route.method, "/\(concretePath)") { res in
                    #expect(
                        res.status == .serviceUnavailable,
                        "\(route.description) bypassed fail-closed registration with \(res.status)"
                    )
                }
            }
        }
    }

    @Test func protectedAPIRoutesRejectWrongTokensWithoutLeakingLength() async throws {
        try await withApp(token: "correct-token") { app in
            for wrongToken in ["wrong-token!!", "x"] {
                try await app.testing().test(
                    .GET,
                    "/api/status",
                    headers: bearerHeaders(wrongToken)
                ) { res in
                    #expect(res.status == .unauthorized)
                }
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

    @Test func healthAndStaticDashboardKeepTheirOwnPolicyWhenTokenUnset() async throws {
        try await withApp(token: nil) { app in
            try await app.testing().test(.GET, "/health") { res in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, "/dashboard") { res in
                #expect(res.status == .ok || res.status == .notFound)
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
                // Report WHY on failure. This passes on macOS and has failed on
                // Linux, where the CI log is the only diagnostic channel there
                // is — a bare status comparison says nothing about whether the
                // template was missing, the path wrong, or the renderer refused.
                #expect(
                    res.status == .ok,
                    "GET / returned \(res.status): \(res.body.string.prefix(400))"
                )
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

    @Test func statusAcceptsCorrectXAbbeyTokenHeader() async throws {
        try await withApp(token: "secret-token") { app in
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: "X-Abbey-Token", value: "secret-token")
            try await app.testing().test(.GET, "/api/status", headers: headers) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func messageListPublishesExactCompoundCursorWithoutWrappingArrayBody() async throws {
        try await withApp(token: "cursor-test-token") { app in
            let headers = bearerHeaders("cursor-test-token")
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
                "/api/messages?limit=1&since=0",
                headers: headers
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
                "/api/messages?limit=1&since=\(stamp.timeIntervalSince1970)&after=\(encodedID)",
                headers: headers
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

    @Test func genericSocialWebhookBypassIsRejectedInDevelopmentWithoutDryRun() async throws {
        try await withApp(
            token: nil,
            environment: .development,
            allowUnsignedSocialForTesting: true
        ) { app in
            try await app.testing().test(
                .POST,
                "/api/social/youtube/webhook",
                headers: jsonHeaders(),
                body: jsonBody(#"{"text":"auth probe","channelId":"c1","author":"u1"}"#)
            ) { res in
                #expect(res.status == .serviceUnavailable)
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

    /// Closes the tasks/goals.md coverage gap: "no test exercises both dedupe layers together."
    /// Drives a retried `channel.chat.message` delivery through the full stack — HTTP route →
    /// `TwitchEventSubReplayGuard` (layer 1, durable claim by delivery id) →
    /// `BotRuntime.handleTwitchChat` ingest-key dedupe (layer 2, `discordMessageId` =
    /// `twitch-eventsub-<delivery id>`) — and proves the layers compose on the retry shapes
    /// each one exists for, with neither double-processing:
    ///
    /// 1. Fresh delivery: layer 1 claims, chat ingests (`.inserted`), ack `notification-ingested`,
    ///    and the claim row is *retained* for the replay window (successful deliveries keep it).
    /// 2. Same delivery id retried: layer 1 rejects before any dispatch — ack `duplicate`, no new
    ///    message row, no new audit row. Layer 2 is never even reached.
    /// 3. Same delivery id retried *after the claim is gone* — the route's own failure path
    ///    releases the claim so Twitch may retry (`TwitchEventSubRoutes.apply` error branch), and
    ///    a claim also ages out of the window naturally. Layer 1 then claims afresh and the
    ///    delivery is reprocessed; layer 2 catches it because the ingest key is derived from the
    ///    delivery id, so ingest returns `.duplicate` → ack `duplicate`, still exactly one
    ///    message row and one audit row. This is the durable backstop layer 1 cannot provide.
    ///
    /// Deliberately pinned non-goal: a delivery with a NEW message id and identical chat content
    /// is not a retry in Twitch's model (retries always reuse the id) — the ingest key follows the
    /// delivery id (`BotRuntime.twitchIngestKey`), so it ingests as a distinct message. Step 4
    /// asserts that, so nobody "fixes" content-based dedupe in by accident.
    @Test func twitchEventSubChatRetryIsCaughtByBothDedupeLayersInSequence() async throws {
        try await withApp(token: nil, allowUnsignedEventSubForTesting: true) { app in
            let messageId = "msg-chat-dedupe-1"
            let ingestKey = "twitch-eventsub-\(messageId)"
            let chatBody = #"""
            {"subscription":{"type":"channel.chat.message","status":"enabled"},
             "event":{"chatter_user_login":"someviewer",
                      "broadcaster_user_login":"somechannel",
                      "message":{"text":"hello abbey"}}}
            """#

            func persistedMessageRows() async throws -> Int {
                try await GuildMessage.query(on: app.db)
                    .filter(\.$discordMessageId == ingestKey)
                    .count()
            }
            func ingestAuditRows() async throws -> Int {
                try await InteractionLog.query(on: app.db)
                    .filter(\.$commandName == "ingestMessage")
                    .count()
            }
            func claimRows() async throws -> Int {
                try await TwitchEventSubDelivery.query(on: app.db)
                    .filter(\.$messageId == messageId)
                    .count()
            }

            // Delivery 1 — fresh: claimed by layer 1, ingested and audited exactly once.
            try await app.testing().test(
                .POST, "/api/twitch/eventsub",
                headers: notificationHeaders(messageId: messageId),
                body: jsonBody(chatBody)
            ) { res in
                #expect(res.status == .ok)
                let ack = try JSONDecoder().decode(AckProbe.self, from: Data(res.body.readableBytesView))
                #expect(ack.ok == true)
                #expect(ack.handled == true)
                #expect(ack.duplicate == false)
                #expect(ack.outcome == "notification-ingested")
            }
            #expect(try await persistedMessageRows() == 1)
            #expect(try await ingestAuditRows() == 1)
            // Success retains the claim for the replay window — release is failure-path only.
            #expect(try await claimRows() == 1)

            // Delivery 2 — identical retry: the durable guard acks duplicate before dispatch.
            try await app.testing().test(
                .POST, "/api/twitch/eventsub",
                headers: notificationHeaders(messageId: messageId),
                body: jsonBody(chatBody)
            ) { res in
                #expect(res.status == .ok)
                let ack = try JSONDecoder().decode(AckProbe.self, from: Data(res.body.readableBytesView))
                #expect(ack.handled == false)
                #expect(ack.duplicate == true)
                #expect(ack.outcome == "duplicate")
            }
            #expect(try await persistedMessageRows() == 1)
            #expect(try await ingestAuditRows() == 1)

            // Delivery 3 — retry after the claim is released (route failure path / window expiry
            // equivalent). Layer 1 lets it through by design; the ingest-key layer must stop the
            // reprocessing. `TwitchEventSubReplayGuard` is stateless over the shared table, so a
            // fresh instance releases the exact claim the route's guard took.
            try await TwitchEventSubReplayGuard().release(messageId, on: app.db)
            #expect(try await claimRows() == 0)
            try await app.testing().test(
                .POST, "/api/twitch/eventsub",
                headers: notificationHeaders(messageId: messageId),
                body: jsonBody(chatBody)
            ) { res in
                #expect(res.status == .ok)
                let ack = try JSONDecoder().decode(AckProbe.self, from: Data(res.body.readableBytesView))
                #expect(ack.handled == false)
                #expect(ack.duplicate == true)
                #expect(ack.outcome == "duplicate")
            }
            #expect(try await persistedMessageRows() == 1)
            #expect(try await ingestAuditRows() == 1)
            // Reprocessing re-claimed the id, so layer 1 guards the next retry again.
            #expect(try await claimRows() == 1)

            // Delivery 4 — NEW message id, identical content: not a retry shape. Neither layer
            // dedupes on content, so this ingests as a distinct message (correct: retries reuse
            // the delivery id; identical text from chat is legitimately a new message).
            try await app.testing().test(
                .POST, "/api/twitch/eventsub",
                headers: notificationHeaders(messageId: "msg-chat-dedupe-2"),
                body: jsonBody(chatBody)
            ) { res in
                #expect(res.status == .ok)
                let ack = try JSONDecoder().decode(AckProbe.self, from: Data(res.body.readableBytesView))
                #expect(ack.handled == true)
                #expect(ack.duplicate == false)
                #expect(ack.outcome == "notification-ingested")
            }
            #expect(try await persistedMessageRows() == 1) // original key untouched
            let secondKeyRows = try await GuildMessage.query(on: app.db)
                .filter(\.$discordMessageId == "twitch-eventsub-msg-chat-dedupe-2")
                .count()
            #expect(secondKeyRows == 1)
            #expect(try await ingestAuditRows() == 2)
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
