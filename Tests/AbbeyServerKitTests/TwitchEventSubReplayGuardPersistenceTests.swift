import AbbeyServerKit
import Fluent
import Foundation
import Testing
import Vapor

/// Fresh migrated in-memory sqlite per call. `Application.make` loads `.env` into the process
/// environment, so `DATABASE_URL` is forced *after* it — otherwise a developer's real database
/// URL would win and these tests would write to it.
func withReplayGuardDatabase(
    _ body: @Sendable (any Database) async throws -> Void
) async throws {
    unsetenv("DISCORD_BOT_TOKEN")
    unsetenv("DISCORD_DEV_GUILD_ID")
    let app = try await Application.make(.testing)
    setenv("DATABASE_URL", "sqlite://memory", 1)
    do {
        _ = try await configureRuntime(app, defaultDatabaseURL: "sqlite://memory")
        try await body(app.db)
        try await app.asyncShutdown()
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

@Suite("Twitch EventSub durable replay guard", .serialized)
struct TwitchEventSubReplayGuardPersistenceTests {
    /// The regression this table exists for: dedupe used to live in a process-lifetime map, so
    /// a restart reprocessed deliveries a previous ack had already reported as duplicates. A
    /// second guard instance over the same database stands in for the restarted process.
    @Test func claimSurvivesANewGuardInstanceOverTheSameDatabase() async throws {
        try await withReplayGuardDatabase { db in
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let beforeRestart = TwitchEventSubReplayGuard()
            let first = try await beforeRestart.claim("delivery-restart", now: now, on: db)

            let afterRestart = TwitchEventSubReplayGuard()
            let replay = try await afterRestart.claim(
                "delivery-restart",
                now: now.addingTimeInterval(5),
                on: db
            )
            #expect(first)
            #expect(!replay)
        }
    }

    /// Unclaimable ids must stay unclaimable — and must not accumulate rows either.
    @Test func emptyMessageIdIsUnclaimableAndStoresNothing() async throws {
        try await withReplayGuardDatabase { db in
            let guardStore = TwitchEventSubReplayGuard()
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let whitespaceFirst = try await guardStore.claim("   ", now: now, on: db)
            let whitespaceAgain = try await guardStore.claim("   ", now: now, on: db)
            let empty = try await guardStore.claim("", now: now, on: db)
            let retained = try await guardStore.retainedCount(now: now, on: db)
            #expect(whitespaceFirst)
            #expect(whitespaceAgain)
            #expect(empty)
            #expect(retained == 0)
        }
    }

    @Test func releaseOfUnknownOrEmptyIdIsHarmlessOnAFreshTable() async throws {
        try await withReplayGuardDatabase { db in
            let guardStore = TwitchEventSubReplayGuard()
            try await guardStore.release("never-claimed", on: db)
            try await guardStore.release("   ", on: db)
            let retained = try await guardStore.retainedCount(on: db)
            let claimed = try await guardStore.claim("first-ever", on: db)
            #expect(retained == 0)
            #expect(claimed)
        }
    }

    @Test func firstClaimWinsAndReplayIsRejected() async throws {
        try await withReplayGuardDatabase { db in
            let guardStore = TwitchEventSubReplayGuard()
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            let first = try await guardStore.claim("delivery-1", now: now, on: db)
            let replay = try await guardStore.claim("delivery-1", now: now, on: db)
            let retained = try await guardStore.retainedCount(now: now, on: db)
            #expect(first)
            #expect(!replay)
            #expect(retained == 1)
        }
    }

    @Test func releaseMakesRetryClaimableAgain() async throws {
        try await withReplayGuardDatabase { db in
            let guardStore = TwitchEventSubReplayGuard()
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let first = try await guardStore.claim("delivery-retry", now: now, on: db)
            #expect(first)

            try await guardStore.release("delivery-retry", on: db)

            let retry = try await guardStore.claim("delivery-retry", now: now, on: db)
            #expect(retry)
        }
    }

    @Test func expiredClaimIsPrunedAndCanWinAgain() async throws {
        try await withReplayGuardDatabase { db in
            let guardStore = TwitchEventSubReplayGuard(window: 600)
            let first = Date(timeIntervalSince1970: 1_700_000_000)
            let initial = try await guardStore.claim("delivery-expired", now: first, on: db)
            #expect(initial)

            let afterWindow = first.addingTimeInterval(601)
            let reclaimed = try await guardStore.claim("delivery-expired", now: afterWindow, on: db)
            let retained = try await guardStore.retainedCount(now: afterWindow, on: db)
            #expect(reclaimed)
            #expect(retained == 1)
        }
    }

    @Test func concurrentClaimsHaveExactlyOneWinner() async throws {
        try await withReplayGuardDatabase { db in
            let guardStore = TwitchEventSubReplayGuard()
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            async let first = guardStore.claim("delivery-race", now: now, on: db)
            async let second = guardStore.claim("delivery-race", now: now, on: db)
            let results = try await [first, second]

            #expect(results.filter { $0 }.count == 1)
            let retained = try await guardStore.retainedCount(now: now, on: db)
            #expect(retained == 1)
        }
    }
}
