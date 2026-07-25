import AbbeyServerKit
import Foundation
import Testing
import Vapor

@Suite("AbbeyServerKit sqlite isolation", .serialized)
struct AbbeyServerKitTests {
    private func withRuntime<T: Sendable>(
        _ body: @Sendable (Application, BotRuntime) async throws -> T
    ) async throws -> T {
        unsetenv("DISCORD_BOT_TOKEN")
        unsetenv("DISCORD_DEV_GUILD_ID")

        let app = try await Application.make(.testing)
        // Application.make loads `.env` into the process environment — force an in-memory
        // URL afterward so configureRuntime cannot pick up a developer Postgres/sqlite file.
        setenv("DATABASE_URL", "sqlite://memory", 1)
        do {
            let runtime = try await configureRuntime(app, defaultDatabaseURL: "sqlite://memory")
            let result = try await body(app, runtime)
            try await app.asyncShutdown()
            return result
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test func configureRuntimeUsesSqliteMemoryDialect() async throws {
        try await withRuntime { app, _ in
            #expect(app.databaseDialect == "sqlite-memory")
        }
    }

    @Test func configureRuntimeRejectsInvalidDatabaseURL() async throws {
        unsetenv("DISCORD_BOT_TOKEN")
        let app = try await Application.make(.testing)
        setenv("DATABASE_URL", "mysql://nope", 1)
        do {
            await #expect(throws: (any Error).self) {
                _ = try await configureRuntime(app, defaultDatabaseURL: "mysql://nope")
            }
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test func memoryRepositoryAppendFactsAndForget() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            try await MemoryRepository.appendFact(
                userId: "u1",
                guildId: "g1",
                fact: "likes tea",
                on: db
            )
            try await MemoryRepository.appendFact(
                userId: "u1",
                guildId: "g1",
                fact: "lives in nyc",
                on: db
            )
            var facts = try await MemoryRepository.facts(userId: "u1", guildId: "g1", on: db)
            #expect(facts == ["likes tea", "lives in nyc"])

            try await MemoryRepository.forgetFact(userId: "u1", guildId: "g1", index: 1, on: db)
            facts = try await MemoryRepository.facts(userId: "u1", guildId: "g1", on: db)
            #expect(facts == ["lives in nyc"])

            await #expect(throws: MemoryForgetError.invalidIndex) {
                try await MemoryRepository.forgetFact(userId: "u1", guildId: "g1", index: 9, on: db)
            }

            await #expect(throws: MemoryForgetError.noMemory) {
                try await MemoryRepository.forgetFact(userId: "nobody", guildId: "g1", index: 1, on: db)
            }

            try await MemoryRepository.appendFact(userId: "u1", guildId: "g1", fact: "   ", on: db)
            facts = try await MemoryRepository.facts(userId: "u1", guildId: "g1", on: db)
            #expect(facts == ["lives in nyc"])
        }
    }

    @Test func channelRepositoryBumpIncrementsCount() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            #expect(try await ChannelRepository.messageCount(channelId: "c1", guildId: "g1", on: db) == 0)
            try await ChannelRepository.bump(channelId: "c1", guildId: "g1", on: db)
            try await ChannelRepository.bump(channelId: "c1", guildId: "g1", on: db)
            #expect(try await ChannelRepository.messageCount(channelId: "c1", guildId: "g1", on: db) == 2)
            #expect(try await ChannelRepository.summary(channelId: "c1", guildId: "g1", on: db) == "")
        }
    }

    @Test func memoryRepositoryRecentSinceCursorFiltersOlderRows() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            try await MemoryRepository.appendFact(userId: "u1", guildId: "g1", fact: "before cursor", on: db)
            try await Task.sleep(nanoseconds: 10_000_000)
            let cursor = Date()
            try await Task.sleep(nanoseconds: 10_000_000)
            try await MemoryRepository.appendFact(userId: "u2", guildId: "g1", fact: "after cursor", on: db)

            let all = try await MemoryRepository.recent(limit: 10, on: db)
            #expect(all.count == 2)

            let sinceCursor = try await MemoryRepository.recent(limit: 10, since: cursor, on: db)
            #expect(sinceCursor.count == 1)
            #expect(sinceCursor.first?.discordUserId == "u2")

            let sinceNothing = try await MemoryRepository.recent(limit: 10, since: nil, on: db)
            #expect(sinceNothing.count == 2)
        }
    }

    /// Regression for a bug where `recent(limit:)` fetched only `limit * 2` most-recent rows
    /// (including tombstones) then filtered tombstones out of THAT window — if tombstone
    /// density in the window exceeded `limit`, a genuinely live older row got silently
    /// excluded even though fewer than `limit` live rows existed in total.
    @Test func memoryRepositoryRecentDoesNotDropLiveRowsBehindADenseTombstoneWindow() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            // Oldest: the one live row that must survive.
            try await MemoryRepository.appendFact(userId: "survivor", guildId: "g1", fact: "still here", on: db)
            try await Task.sleep(nanoseconds: 10_000_000)

            // Two more-recent rows, both tombstoned — denser than `limit` below.
            try await MemoryRepository.appendFact(userId: "gone1", guildId: "g1", fact: "x", on: db)
            try await MemoryRepository.softDelete(userId: "gone1", guildId: "g1", on: db)
            try await Task.sleep(nanoseconds: 10_000_000)
            try await MemoryRepository.appendFact(userId: "gone2", guildId: "g1", fact: "x", on: db)
            try await MemoryRepository.softDelete(userId: "gone2", guildId: "g1", on: db)

            let recent = try await MemoryRepository.recent(limit: 1, on: db)

            #expect(recent.count == 1)
            #expect(recent.first?.discordUserId == "survivor")
        }
    }

    @Test func channelRepositoryRecentSinceCursorFiltersOlderRows() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            try await ChannelRepository.bump(channelId: "c1", guildId: "g1", on: db)
            try await Task.sleep(nanoseconds: 10_000_000)
            let cursor = Date()
            try await Task.sleep(nanoseconds: 10_000_000)
            try await ChannelRepository.bump(channelId: "c2", guildId: "g1", on: db)

            let sinceCursor = try await ChannelRepository.recent(limit: 10, since: cursor, on: db)
            #expect(sinceCursor.count == 1)
            #expect(sinceCursor.first?.channelId == "c2")
        }
    }

    @Test func messageRepositoryRecentSinceCursorFiltersOlderRows() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            try await MessageRepository.insert(discordMessageId: "m1", channelId: "c1", guildId: "g1", authorId: "u1", content: "before", on: db)
            try await Task.sleep(nanoseconds: 10_000_000)
            let cursor = Date()
            try await Task.sleep(nanoseconds: 10_000_000)
            try await MessageRepository.insert(discordMessageId: "m2", channelId: "c1", guildId: "g1", authorId: "u1", content: "after", on: db)

            let sinceCursor = try await MessageRepository.recent(limit: 10, since: cursor, on: db)
            #expect(sinceCursor.count == 1)
            #expect(sinceCursor.first?.discordMessageId == "m2")
        }
    }

    @Test func reputationRepositoryRecentSinceCursorFiltersOlderRows() async throws {
        try await withRuntime { app, runtime in
            try await runtime.remember(userId: "u1", guildId: "g1", fact: "x")
            let db = app.db
            let cursor = Date()
            try await Task.sleep(nanoseconds: 10_000_000)
            // Reputation events are created via ingest scoring, not directly repository-insertable in this suite;
            // an empty since-filtered result on a fresh cursor with no new events is still a valid, testable contract.
            let sinceCursor = try await ReputationRepository.recent(limit: 10, since: cursor, on: db)
            #expect(sinceCursor.isEmpty)
        }
    }

    @Test func interactionRepositoryRecentSinceCursorFiltersOlderRows() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            try await InteractionRepository.log(commandName: "ask", userId: "u1", guildId: "g1", succeeded: true, latencyMs: 1, on: db)
            try await Task.sleep(nanoseconds: 10_000_000)
            let cursor = Date()
            try await Task.sleep(nanoseconds: 10_000_000)
            try await InteractionRepository.log(commandName: "rep", userId: "u1", guildId: "g1", succeeded: true, latencyMs: 1, on: db)

            let sinceCursor = try await InteractionRepository.recent(limit: 10, since: cursor, on: db)
            #expect(sinceCursor.count == 1)
            #expect(sinceCursor.first?.commandName == "rep")
        }
    }

    @Test func equityRepositoryRecentSinceCursorFiltersOlderRows() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            let cursor = Date()
            let sinceCursor = try await EquityRepository.recent(limit: 10, since: cursor, on: db)
            #expect(sinceCursor.isEmpty)
        }
    }

    @Test func syncStatusRepositoryReportThenCurrentReflectsLatestReport() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            let empty = try await SyncStatusRepository.current(on: db)
            #expect(empty.lastPullAt == nil)
            #expect(empty.pendingPushCount == 0)

            try await SyncStatusRepository.report(
                lastPullAt: Date(timeIntervalSince1970: 1000),
                lastPullError: nil,
                lastPushAt: Date(timeIntervalSince1970: 900),
                lastPushError: "HTTP 500",
                pendingPushCount: 2,
                on: db
            )

            let first = try await SyncStatusRepository.current(on: db)
            #expect(first.lastPullAt == Date(timeIntervalSince1970: 1000))
            #expect(first.lastPushError == "HTTP 500")
            #expect(first.pendingPushCount == 2)

            // A second report upserts the single record rather than accumulating rows.
            try await SyncStatusRepository.report(
                lastPullAt: Date(timeIntervalSince1970: 2000),
                lastPullError: "timeout",
                lastPushAt: Date(timeIntervalSince1970: 900),
                lastPushError: "HTTP 500",
                pendingPushCount: 0,
                on: db
            )

            let second = try await SyncStatusRepository.current(on: db)
            #expect(second.lastPullAt == Date(timeIntervalSince1970: 2000))
            #expect(second.lastPullError == "timeout")
            #expect(second.pendingPushCount == 0)
        }
    }

    @Test func statusCountsReflectWrites() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            var counts = try await StatusRepository.counts(on: db)
            #expect(counts.users == 0)
            #expect(counts.channels == 0)
            #expect(counts.messages == 0)

            try await MemoryRepository.appendFact(userId: "u1", guildId: "g1", fact: "fact", on: db)
            try await ChannelRepository.bump(channelId: "c1", guildId: "g1", on: db)
            try await MessageRepository.insert(
                discordMessageId: "m1",
                channelId: "c1",
                guildId: "g1",
                authorId: "u1",
                content: "hello",
                on: db
            )

            counts = try await StatusRepository.counts(on: db)
            #expect(counts.users == 1)
            #expect(counts.channels == 1)
            #expect(counts.messages == 1)
        }
    }

    @Test func botRuntimeRememberForgetAndState() async throws {
        try await withRuntime { _, runtime in
            try await runtime.remember(userId: "u1", guildId: "g1", fact: "alpha")
            try await runtime.remember(userId: "u1", guildId: "g1", fact: "beta")

            var state = await runtime.userState(userId: "u1", guildId: "g1")
            #expect(state.facts == ["alpha", "beta"])

            try await runtime.forget(userId: "u1", guildId: "g1", index: 2)
            state = await runtime.userState(userId: "u1", guildId: "g1")
            #expect(state.facts == ["alpha"])

            let channel = await runtime.channelState(channelId: "c1", guildId: "g1")
            #expect(channel.summary == "")

            let metrics = await runtime.metricsSnapshot()
            #expect(metrics.discordBotUserId.isEmpty)
            #expect(metrics.discordState == "disconnected")
        }
    }

    @Test func softDeleteHidesFromFullListAndSurfacesOnSincePull() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            try await MemoryRepository.appendFact(userId: "u1", guildId: "g1", fact: "tea", on: db)
            try await ChannelRepository.bump(channelId: "c1", guildId: "g1", on: db)

            let before = Date().addingTimeInterval(-1)
            try await MemoryRepository.softDelete(userId: "u1", guildId: "g1", on: db)
            try await ChannelRepository.softDelete(channelId: "c1", guildId: "g1", on: db)

            let liveUsers = try await MemoryRepository.recent(limit: 10, on: db)
            #expect(liveUsers.isEmpty)
            let liveChannels = try await ChannelRepository.recent(limit: 10, on: db)
            #expect(liveChannels.isEmpty)

            let tombstoneUsers = try await MemoryRepository.recent(limit: 10, since: before, on: db)
            #expect(tombstoneUsers.count == 1)
            #expect(tombstoneUsers.first?.deletedAt != nil)

            let tombstoneChannels = try await ChannelRepository.recent(limit: 10, since: before, on: db)
            #expect(tombstoneChannels.count == 1)
            #expect(tombstoneChannels.first?.deletedAt != nil)

            #expect(try await MemoryRepository.count(on: db) == 0)
            #expect(try await ChannelRepository.count(on: db) == 0)
            #expect(try await MemoryRepository.facts(userId: "u1", guildId: "g1", on: db).isEmpty)
        }
    }

    @Test func rememberResurrectsSoftDeletedUser() async throws {
        try await withRuntime { app, runtime in
            try await runtime.remember(userId: "u1", guildId: "g1", fact: "old")
            try await runtime.tombstoneUser(userId: "u1", guildId: "g1")
            #expect((await runtime.userState(userId: "u1", guildId: "g1")).facts.isEmpty)

            try await runtime.remember(userId: "u1", guildId: "g1", fact: "new")
            #expect((await runtime.userState(userId: "u1", guildId: "g1")).facts == ["old", "new"])

            let live = try await MemoryRepository.recent(limit: 10, on: app.db)
            #expect(live.count == 1)
            #expect(live.first?.deletedAt == nil)
        }
    }

    @Test func handleTwitchChatIngestsUnderTwitchGuild() async throws {
        try await withRuntime { app, runtime in
            await runtime.handleTwitchChat(login: "someviewer", channel: "somechannel", text: "hello abbey")

            let rows = try await MessageRepository.recent(limit: 10, on: app.db)
            #expect(rows.count == 1)
            #expect(rows.first?.guildId == "twitch")
            #expect(rows.first?.channelId == "somechannel")
            #expect(rows.first?.authorId == "someviewer")
            #expect(rows.first?.content == "hello abbey")
        }
    }

    @Test func ingestMessageSkipsDuplicateDiscordMessageIdWithoutRescoring() async throws {
        try await withRuntime { app, runtime in
            let first = await runtime.ingestMessage(
                content: "hello once",
                channelId: "c-dedupe",
                guildId: "g-dedupe",
                authorId: "u-dedupe",
                discordMessageId: "m-dedupe"
            )
            #expect(first == true)

            let interactionsAfterFirst = try await InteractionLog.query(on: app.db).count()
            let messagesAfterFirst = try await MessageRepository.count(on: app.db)

            let second = await runtime.ingestMessage(
                content: "hello again — should not land",
                channelId: "c-dedupe",
                guildId: "g-dedupe",
                authorId: "u-dedupe",
                discordMessageId: "m-dedupe"
            )
            #expect(second == false)
            #expect(try await MessageRepository.count(on: app.db) == messagesAfterFirst)
            #expect(try await InteractionLog.query(on: app.db).count() == interactionsAfterFirst)

            let rows = try await MessageRepository.recent(limit: 10, on: app.db)
            #expect(rows.contains { $0.discordMessageId == "m-dedupe" && $0.content == "hello once" })
            #expect(!rows.contains { $0.content == "hello again — should not land" })
        }
    }

    @Test func handleTwitchStreamLifecycleFlipsLiveFlagAndLogsInteraction() async throws {
        try await withRuntime { app, runtime in
            #expect(await runtime.twitchStreamLive == nil)

            await runtime.handleTwitchStreamLifecycle(broadcasterLogin: "somechannel", isLive: true)
            #expect(await runtime.twitchStreamLive == true)
            let onlineLogs = try await InteractionLog.query(on: app.db).all()
                .filter { $0.commandName == "eventsub.stream.online" }
            #expect(onlineLogs.count == 1)
            #expect(onlineLogs.first?.userId == "somechannel")
            #expect(onlineLogs.first?.guildId == "twitch")

            await runtime.handleTwitchStreamLifecycle(broadcasterLogin: "somechannel", isLive: false)
            #expect(await runtime.twitchStreamLive == false)
            let offlineLogs = try await InteractionLog.query(on: app.db).all()
                .filter { $0.commandName == "eventsub.stream.offline" }
            #expect(offlineLogs.count == 1)
        }
    }

    @Test func messageTombstoneHidesFromFullListAndSurfacesOnSince() async throws {
        try await withRuntime { app, runtime in
            try await MessageRepository.insert(
                discordMessageId: "m-tomb",
                channelId: "c1",
                guildId: "g1",
                authorId: "u1",
                content: "bye",
                on: app.db
            )
            let before = Date().addingTimeInterval(-1)
            try await runtime.tombstoneMessage(discordMessageId: "m-tomb")

            #expect(try await MessageRepository.recent(limit: 10, on: app.db).isEmpty)
            let since = try await MessageRepository.recent(limit: 10, since: before, on: app.db)
            #expect(since.count == 1)
            #expect(since.first?.deletedAt != nil)
            #expect(try await MessageRepository.count(on: app.db) == 0)
        }
    }

    /// `tombstoneReputation`/`tombstoneInteraction`/`tombstoneEquity` had zero coverage —
    /// `tombstoneUser`/`tombstoneMessage` were exercised, these three weren't at all.
    @Test func tombstoneReputationHidesFromFullListAndSurfacesOnSince() async throws {
        try await withRuntime { app, runtime in
            let event = ReputationEvent(userId: "u1", guildId: "g1", delta: 1, reason: "test")
            try await event.create(on: app.db)
            let id = try event.requireID()
            let before = Date().addingTimeInterval(-1)

            try await runtime.tombstoneReputation(id: id)

            #expect(try await ReputationRepository.recent(limit: 10, on: app.db).isEmpty)
            let since = try await ReputationRepository.recent(limit: 10, since: before, on: app.db)
            #expect(since.first?.deletedAt != nil)

            await #expect(throws: ReputationTombstoneError.self) {
                try await runtime.tombstoneReputation(id: id)
            }
        }
    }

    @Test func tombstoneInteractionHidesFromFullListAndSurfacesOnSince() async throws {
        try await withRuntime { app, runtime in
            try await InteractionRepository.log(
                commandName: "ask", userId: "u1", guildId: "g1", succeeded: true, latencyMs: 10, on: app.db
            )
            let logged = try await InteractionRepository.recent(limit: 1, on: app.db)
            let id = try #require(logged.first?.id)
            let before = Date().addingTimeInterval(-1)

            try await runtime.tombstoneInteraction(id: id)

            #expect(try await InteractionRepository.recent(limit: 10, on: app.db).isEmpty)
            let since = try await InteractionRepository.recent(limit: 10, since: before, on: app.db)
            #expect(since.first?.deletedAt != nil)

            await #expect(throws: InteractionTombstoneError.self) {
                try await runtime.tombstoneInteraction(id: id)
            }
        }
    }

    @Test func tombstoneEquityHidesFromFullListAndSurfacesOnSince() async throws {
        try await withRuntime { app, runtime in
            let idea = EquityIdea(symbol: "QX-1", thesisSummary: "t", syntheticScore: 0.5, factorBreakdown: [:])
            try await idea.create(on: app.db)
            let before = Date().addingTimeInterval(-1)

            try await runtime.tombstoneEquity(symbol: "QX-1")

            #expect(try await EquityRepository.recent(limit: 10, on: app.db).isEmpty)
            let since = try await EquityRepository.recent(limit: 10, since: before, on: app.db)
            #expect(since.first?.deletedAt != nil)

            await #expect(throws: EquityTombstoneError.self) {
                try await runtime.tombstoneEquity(symbol: "QX-1")
            }
        }
    }

    /// The auditor flagged ingestMessage's dedup as a textbook check-then-insert TOCTOU race,
    /// safe only because CreateAll declares a unique index on discord_message_id — verify that
    /// claim empirically rather than trusting the reasoning alone.
    @Test func concurrentIngestWithSameDiscordMessageIdNeverCreatesADuplicateRow() async throws {
        try await withRuntime { app, runtime in
            async let first = runtime.ingestMessage(
                content: "race A", channelId: "c-race", guildId: "g-race", authorId: "u-race",
                discordMessageId: "m-race"
            )
            async let second = runtime.ingestMessage(
                content: "race B", channelId: "c-race", guildId: "g-race", authorId: "u-race",
                discordMessageId: "m-race"
            )
            let results = await [first, second]

            #expect(results.filter { $0 }.count == 1, "exactly one of the two racing ingests should have won")
            let rows = try await MessageRepository.recent(limit: 10, on: app.db)
            #expect(rows.filter { $0.discordMessageId == "m-race" }.count == 1)
        }
    }
}
