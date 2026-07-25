import AbbeyServerKit
import Fluent
import Foundation
import Testing
import Vapor

@Suite("ServerSyncApply into a local Fluent database", .serialized)
struct ServerSyncApplyTests {
    private func withRuntime<T: Sendable>(
        _ body: @Sendable (Application, BotRuntime) async throws -> T
    ) async throws -> T {
        unsetenv("DISCORD_BOT_TOKEN")
        unsetenv("DISCORD_DEV_GUILD_ID")

        let app = try await Application.make(.testing)
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

    @Test func insertsMissingUserAndSkipsOlderRemote() async throws {
        try await withRuntime { app, _ in
            let inserted = try await ServerSyncApply.applyUsers(
                [.init(
                    compositeKey: "g1:u1",
                    discordUserId: "u1",
                    guildId: "g1",
                    facts: ["likes tea"],
                    reputation: 0.7,
                    interactionCount: 3,
                    updatedAt: Date()
                )],
                on: app.db
            )
            #expect(inserted == 1)

            let local = try await UserMemory.query(on: app.db)
                .filter(\.$compositeKey == "g1:u1")
                .first()
            #expect(local?.facts == ["likes tea"])
            #expect(local?.reputation == 0.7)

            // A remote row older than the local updatedAt loses LWW and does not clobber.
            _ = try await ServerSyncApply.applyUsers(
                [.init(
                    compositeKey: "g1:u1",
                    discordUserId: "u1",
                    guildId: "g1",
                    facts: ["stale"],
                    reputation: 0.1,
                    interactionCount: 0,
                    updatedAt: Date().addingTimeInterval(-3600)
                )],
                on: app.db
            )
            let after = try await UserMemory.query(on: app.db)
                .filter(\.$compositeKey == "g1:u1")
                .first()
            #expect(after?.facts == ["likes tea"])
        }
    }

    @Test func userTombstoneHardDeletesLocalRow() async throws {
        try await withRuntime { app, _ in
            try await UserMemory(discordUserId: "u2", guildId: "g1").create(on: app.db)

            _ = try await ServerSyncApply.applyUsers(
                [.init(
                    compositeKey: "g1:u2",
                    discordUserId: "u2",
                    guildId: "g1",
                    facts: [],
                    reputation: 0.5,
                    interactionCount: 0,
                    updatedAt: Date().addingTimeInterval(60),
                    deletedAt: Date().addingTimeInterval(60)
                )],
                on: app.db
            )

            let local = try await UserMemory.query(on: app.db)
                .filter(\.$compositeKey == "g1:u2")
                .first()
            #expect(local == nil)
        }
    }

    @Test func tombstoneForUnknownUserDoesNotInsert() async throws {
        try await withRuntime { app, _ in
            _ = try await ServerSyncApply.applyUsers(
                [.init(
                    compositeKey: "g1:ghost",
                    discordUserId: "ghost",
                    guildId: "g1",
                    facts: [],
                    reputation: 0.5,
                    interactionCount: 0,
                    deletedAt: Date()
                )],
                on: app.db
            )
            let count = try await UserMemory.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test func messagesInsertIfMissingAndTombstoneDeletes() async throws {
        try await withRuntime { app, _ in
            let inserted = try await ServerSyncApply.applyMessages(
                [.init(discordMessageId: "m1", channelId: "c1", guildId: "g1", authorId: "u1", content: "hi")],
                on: app.db
            )
            #expect(inserted == 1)

            // Existing row is not clobbered and not double-counted.
            let again = try await ServerSyncApply.applyMessages(
                [.init(discordMessageId: "m1", channelId: "c1", guildId: "g1", authorId: "u1", content: "changed")],
                on: app.db
            )
            #expect(again == 0)
            let local = try await GuildMessage.query(on: app.db)
                .filter(\.$discordMessageId == "m1")
                .first()
            #expect(local?.content == "hi")

            _ = try await ServerSyncApply.applyMessages(
                [.init(
                    discordMessageId: "m1",
                    channelId: "c1",
                    guildId: "g1",
                    authorId: "u1",
                    content: "hi",
                    deletedAt: Date()
                )],
                on: app.db
            )
            let gone = try await GuildMessage.query(on: app.db)
                .filter(\.$discordMessageId == "m1")
                .first()
            #expect(gone == nil)
        }
    }

    @Test func reputationAndInteractionsKeyByServerIdAndSkipMissingIds() async throws {
        try await withRuntime { app, _ in
            let repId = UUID()
            let applied = try await ServerSyncApply.applyReputation(
                [
                    .init(id: repId, userId: "u1", guildId: "g1", delta: 0.2, reason: "helpful"),
                    .init(id: nil, userId: "u2", guildId: "g1", delta: 0.1, reason: "no id — skipped")
                ],
                on: app.db
            )
            #expect(applied == 1)
            let localRep = try await ReputationEvent.query(on: app.db).all()
            #expect(localRep.count == 1)
            #expect(localRep.first?.id == repId)

            // Same id again → no duplicate.
            let again = try await ServerSyncApply.applyReputation(
                [.init(id: repId, userId: "u1", guildId: "g1", delta: 0.2, reason: "helpful")],
                on: app.db
            )
            #expect(again == 0)

            let logId = UUID()
            _ = try await ServerSyncApply.applyInteractions(
                [.init(id: logId, commandName: "ask", userId: "u1", guildId: "g1", succeeded: true, latencyMs: 12)],
                on: app.db
            )
            #expect(try await InteractionLog.query(on: app.db).count() == 1)

            _ = try await ServerSyncApply.applyInteractions(
                [.init(
                    id: logId,
                    commandName: "ask",
                    userId: "u1",
                    guildId: "g1",
                    succeeded: true,
                    latencyMs: 12,
                    deletedAt: Date()
                )],
                on: app.db
            )
            #expect(try await InteractionLog.query(on: app.db).count() == 0)
        }
    }

    @Test func equityUpsertsBySymbolAndTombstoneComparesGeneratedAt() async throws {
        try await withRuntime { app, _ in
            _ = try await ServerSyncApply.applyEquity(
                [.init(
                    symbol: "QX",
                    thesisSummary: "thesis",
                    syntheticScore: 0.6,
                    factorBreakdown: ["m": 0.6],
                    generatedAt: Date()
                )],
                on: app.db
            )
            let local = try await EquityIdea.query(on: app.db).filter(\.$symbol == "QX").first()
            #expect(local?.thesisSummary == "thesis")

            // Tombstone older than the local generatedAt is ignored (regenerated idea survives).
            _ = try await ServerSyncApply.applyEquity(
                [.init(
                    symbol: "QX",
                    thesisSummary: "thesis",
                    syntheticScore: 0.6,
                    factorBreakdown: ["m": 0.6],
                    deletedAt: Date().addingTimeInterval(-3600)
                )],
                on: app.db
            )
            #expect(try await EquityIdea.query(on: app.db).filter(\.$symbol == "QX").count() == 1)

            _ = try await ServerSyncApply.applyEquity(
                [.init(
                    symbol: "QX",
                    thesisSummary: "thesis",
                    syntheticScore: 0.6,
                    factorBreakdown: ["m": 0.6],
                    deletedAt: Date().addingTimeInterval(3600)
                )],
                on: app.db
            )
            #expect(try await EquityIdea.query(on: app.db).filter(\.$symbol == "QX").count() == 0)
        }
    }

    @Test func applyAllReturnsPerEntityCounts() async throws {
        try await withRuntime { app, _ in
            let counts = try await ServerSyncApply.apply(
                users: [.init(
                    compositeKey: "g1:u1",
                    discordUserId: "u1",
                    guildId: "g1",
                    facts: [],
                    reputation: 0.5,
                    interactionCount: 0
                )],
                channels: [.init(
                    compositeKey: "g1:c1",
                    channelId: "c1",
                    guildId: "g1",
                    summary: "s",
                    messageCount: 2
                )],
                messages: [.init(discordMessageId: "m1", channelId: "c1", guildId: "g1", authorId: "u1", content: "hi")],
                reputation: [],
                interactions: [],
                equity: [],
                on: app.db
            )
            #expect(counts.usersApplied == 1)
            #expect(counts.channelsApplied == 1)
            #expect(counts.messagesApplied == 1)
            #expect(counts.reputationApplied == 0)
            #expect(counts.summary.contains("1 users"))
        }
    }
}

@Suite("Sync cursor file store")
struct SyncCursorFileStoreTests {
    @Test func missingFileDegradesToNil() {
        let store = SyncCursorFileStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("abbey-cursor-missing-\(UUID().uuidString)")
        )
        #expect(store.loadLastPullSuccess() == nil)
    }

    @Test func garbageContentDegradesToNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-cursor-garbage-\(UUID().uuidString)")
        try "not a number".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SyncCursorFileStore(fileURL: url).loadLastPullSuccess() == nil)
    }

    @Test func roundTripsEpochSeconds() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-cursor-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SyncCursorFileStore(fileURL: url)
        let stamp = Date(timeIntervalSince1970: 1_752_000_000.5)
        try store.saveLastPullSuccess(stamp)

        let loaded = store.loadLastPullSuccess()
        #expect(loaded != nil)
        #expect(abs(loaded!.timeIntervalSince1970 - stamp.timeIntervalSince1970) < 0.001)
    }

    @Test func createsParentDirectoryOnSave() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-cursor-dir-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("cli-sync-cursor")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SyncCursorFileStore(fileURL: url)
        try store.saveLastPullSuccess(Date())
        #expect(store.loadLastPullSuccess() != nil)
    }
}
