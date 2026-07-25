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

        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            let result = try await body(app)
            try await app.asyncShutdown()
            unsetenv("ABBEY_API_TOKEN")
            unsetenv("DATABASE_URL")
            return result
        } catch {
            try? await app.asyncShutdown()
            unsetenv("ABBEY_API_TOKEN")
            unsetenv("DATABASE_URL")
            throw error
        }
    }

    private func bearerHeaders(_ token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token)
        return headers
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
}
