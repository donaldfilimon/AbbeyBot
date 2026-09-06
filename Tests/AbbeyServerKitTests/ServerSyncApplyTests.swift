import AbbeyCore
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

    @Test(arguments: [Int.min, -1, 0, 2, Int.max])
    func forgetRejectsInvalidIndicesWithoutMutating(index: Int) async throws {
        try await withRuntime { app, runtime in
            try await MemoryRepository.appendFact(userId: "u", guildId: "g", fact: "keep", on: app.db)
            await #expect(throws: MemoryForgetError.invalidIndex) {
                try await MemoryRepository.forgetFact(userId: "u", guildId: "g", index: index, on: app.db)
            }
            await #expect(throws: MemoryForgetError.invalidIndex) {
                try await runtime.forget(userId: "u", guildId: "g", index: index)
            }
            #expect(try await MemoryRepository.facts(userId: "u", guildId: "g", on: app.db) == ["keep"])
        }
    }

    enum UserMutation: CaseIterable, Sendable {
        case append, forget, interaction, penalty, tombstone, resurrect
    }

    @Test(arguments: UserMutation.allCases)
    func localUserMutationDefeatsStaleRemoteUpdateAndTombstone(mutation: UserMutation) async throws {
        try await withRuntime { app, _ in
            let source = Date(timeIntervalSince1970: 1_000)
            let stale = Date(timeIntervalSince1970: 2_000)
            let initial = ServerSyncDTO.User(
                compositeKey: "g:u", discordUserId: "u", guildId: "g",
                facts: ["first", "second"], reputation: 0.5, interactionCount: 1, updatedAt: source
            )
            try await ServerSyncApply.applyUsers([initial], on: app.db)
            switch mutation {
            case .append:
                try await MemoryRepository.appendFact(userId: "u", guildId: "g", fact: "local", on: app.db)
            case .forget:
                try await MemoryRepository.forgetFact(userId: "u", guildId: "g", index: 1, on: app.db)
            case .interaction, .penalty:
                let brain = FluentSocialBrain(db: app.db, eventBus: EventBus(), decay: { 0.9 })
                await brain.warmCache()
                if mutation == .interaction {
                    await brain.recordInteraction(userId: "u", guildId: "g", quality: 0.9)
                } else {
                    await brain.penalize(userId: "u", guildId: "g", reason: "test")
                }
            case .tombstone:
                try await MemoryRepository.softDelete(userId: "u", guildId: "g", on: app.db)
            case .resurrect:
                let row = try #require(try await UserMemory.query(on: app.db).first())
                row.deletedAt = source
                try await row.save(on: app.db)
                try await MemoryRepository.appendFact(userId: "u", guildId: "g", fact: "first", on: app.db)
            }
            let local = try #require(try await UserMemory.query(on: app.db).first())
            #expect(local.sourceUpdatedAt == nil)
            let localStamp = try #require(local.updatedAt)
            #expect(localStamp > stale)
            if mutation == .resurrect { #expect(local.deletedAt == nil) }

            for deletedAt in [nil, stale] as [Date?] {
                try await ServerSyncApply.applyUsers([.init(
                    compositeKey: "g:u", discordUserId: "u", guildId: "g",
                    facts: ["stale"], reputation: 0.1, interactionCount: 0,
                    updatedAt: stale, deletedAt: deletedAt
                )], on: app.db)
                let after = try #require(try await UserMemory.query(on: app.db).first())
                #expect(after.facts == local.facts)
                #expect(after.reputation == local.reputation)
                #expect(after.interactionCount == local.interactionCount)
                #expect(after.deletedAt == local.deletedAt)
                #expect(after.sourceUpdatedAt == nil)
                #expect(after.updatedAt == localStamp)
            }
        }
    }

    enum ChannelMutation: CaseIterable, Sendable {
        case bump, consolidate, tombstone, resurrect
    }

    @Test(arguments: ChannelMutation.allCases)
    func localChannelMutationDefeatsStaleRemoteUpdateAndTombstone(mutation: ChannelMutation) async throws {
        try await withRuntime { app, _ in
            let source = Date(timeIntervalSince1970: 1_000)
            let stale = Date(timeIntervalSince1970: 2_000)
            try await ServerSyncApply.applyChannels([.init(
                compositeKey: "g:c", channelId: "c", guildId: "g",
                summary: "remote", messageCount: 4, updatedAt: source
            )], on: app.db)
            switch mutation {
            case .bump:
                try await ChannelRepository.bump(channelId: "c", guildId: "g", on: app.db)
            case .consolidate:
                try await MessageRepository.insert(
                    discordMessageId: "m", channelId: "c", guildId: "g",
                    authorId: "u", content: "local message", on: app.db
                )
                let scheduler = FluentScheduler(
                    db: app.db, logger: app.logger, eventBus: EventBus(), metrics: EngineMetrics(),
                    cooldownSeconds: { 0 }, consolidationIntervalMinutes: { 1 }
                )
                await scheduler.consolidateAllChannels()
            case .tombstone:
                try await ChannelRepository.softDelete(channelId: "c", guildId: "g", on: app.db)
            case .resurrect:
                let row = try #require(try await ChannelContext.query(on: app.db).first())
                row.deletedAt = source
                try await row.save(on: app.db)
                try await ChannelRepository.bump(channelId: "c", guildId: "g", on: app.db)
            }
            let local = try #require(try await ChannelContext.query(on: app.db).first())
            #expect(local.sourceUpdatedAt == nil)
            let localStamp = try #require(local.updatedAt)
            #expect(localStamp > stale)
            if mutation == .resurrect { #expect(local.deletedAt == nil) }

            for deletedAt in [nil, stale] as [Date?] {
                try await ServerSyncApply.applyChannels([.init(
                    compositeKey: "g:c", channelId: "c", guildId: "g",
                    summary: "stale", messageCount: 0, updatedAt: stale, deletedAt: deletedAt
                )], on: app.db)
                let after = try #require(try await ChannelContext.query(on: app.db).first())
                #expect(after.summary == local.summary)
                #expect(after.messageCount == local.messageCount)
                #expect(after.deletedAt == local.deletedAt)
                #expect(after.sourceUpdatedAt == nil)
                #expect(after.updatedAt == localStamp)
            }
        }
    }

    @Test func duplicateAndBlankFactsPreserveSourceClockForLaterRemoteChanges() async throws {
        try await withRuntime { app, _ in
            let source = Date(timeIntervalSince1970: 1_000)
            let later = Date(timeIntervalSince1970: 2_000)
            try await ServerSyncApply.applyUsers([.init(
                compositeKey: "g:u", discordUserId: "u", guildId: "g",
                facts: ["keep"], reputation: 0.5, interactionCount: 1, updatedAt: source
            )], on: app.db)
            for fact in [" keep ", "   "] {
                try await MemoryRepository.appendFact(userId: "u", guildId: "g", fact: fact, on: app.db)
            }
            let local = try #require(try await UserMemory.query(on: app.db).first())
            #expect(local.sourceUpdatedAt == source)
            try await ServerSyncApply.applyUsers([.init(
                compositeKey: "g:u", discordUserId: "u", guildId: "g",
                facts: [], reputation: 0.5, interactionCount: 1, updatedAt: later, deletedAt: later
            )], on: app.db)
            #expect(try await UserMemory.query(on: app.db).count() == 0)
        }
    }

    @Test func channelRemoteUpdatesAndTombstonesKeepUsingSourceClock() async throws {
        try await withRuntime { app, _ in
            for seconds in [1_000.0, 2_000.0] {
                let stamp = Date(timeIntervalSince1970: seconds)
                try await ServerSyncApply.applyChannels([.init(
                    compositeKey: "g:c", channelId: "c", guildId: "g",
                    summary: "remote \(seconds)", messageCount: 4, updatedAt: stamp
                )], on: app.db)
                let row = try #require(try await ChannelContext.query(on: app.db).first())
                #expect(row.sourceUpdatedAt == stamp)
                #expect(row.summary == "remote \(seconds)")
            }
            let stamp = Date(timeIntervalSince1970: 3_000)
            try await ServerSyncApply.applyChannels([.init(
                compositeKey: "g:c", channelId: "c", guildId: "g",
                summary: "", messageCount: 0, updatedAt: stamp, deletedAt: stamp
            )], on: app.db)
            #expect(try await ChannelContext.query(on: app.db).count() == 0)
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

    @Test func preservesSourceClockAndAcceptsLaterRemoteUpdate() async throws {
        try await withRuntime { app, _ in
            let firstStamp = Date(timeIntervalSince1970: 1_000)
            let laterStamp = Date(timeIntervalSince1970: 1_001)
            _ = try await ServerSyncApply.applyUsers(
                [.init(
                    compositeKey: "g1:clock",
                    discordUserId: "clock",
                    guildId: "g1",
                    facts: ["first"],
                    reputation: 0.5,
                    interactionCount: 1,
                    updatedAt: firstStamp
                )],
                on: app.db
            )

            let first = try #require(try await UserMemory.query(on: app.db)
                .filter(\.$compositeKey == "g1:clock")
                .first())
            #expect(first.sourceUpdatedAt == firstStamp)
            #expect((first.updatedAt ?? .distantPast) > laterStamp)

            _ = try await ServerSyncApply.applyUsers(
                [.init(
                    compositeKey: "g1:clock",
                    discordUserId: "clock",
                    guildId: "g1",
                    facts: ["later"],
                    reputation: 0.8,
                    interactionCount: 2,
                    updatedAt: laterStamp
                )],
                on: app.db
            )

            let updated = try #require(try await UserMemory.query(on: app.db)
                .filter(\.$compositeKey == "g1:clock")
                .first())
            #expect(updated.facts == ["later"])
            #expect(updated.sourceUpdatedAt == laterStamp)
        }
    }

    @Test func preservesSourceCreationAndGenerationClocks() async throws {
        try await withRuntime { app, _ in
            let sourceStamp = Date(timeIntervalSince1970: 2_000)
            _ = try await ServerSyncApply.applyMessages(
                [.init(
                    discordMessageId: "source-time",
                    channelId: "c",
                    guildId: "g",
                    authorId: "u",
                    content: "hello",
                    createdAt: sourceStamp
                )],
                on: app.db
            )
            _ = try await ServerSyncApply.applyEquity(
                [.init(
                    symbol: "TIME",
                    thesisSummary: "synthetic",
                    syntheticScore: 0.5,
                    factorBreakdown: [:],
                    generatedAt: sourceStamp
                )],
                on: app.db
            )

            let message = try #require(try await GuildMessage.query(on: app.db)
                .filter(\.$discordMessageId == "source-time")
                .first())
            let equity = try #require(try await EquityIdea.query(on: app.db)
                .filter(\.$symbol == "TIME")
                .first())
            #expect(message.sourceCreatedAt == sourceStamp)
            #expect(equity.sourceGeneratedAt == sourceStamp)
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

    @Test func incrementalMessagePagesAreOldestChangeFirstAndIncludeTombstones() async throws {
        try await withRuntime { app, _ in
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            func insert(_ id: String, createdOffset: TimeInterval, deletedOffset: TimeInterval? = nil) async throws {
                let row = GuildMessage(
                    discordMessageId: id,
                    channelId: "c1",
                    guildId: "g1",
                    authorId: "u1",
                    content: id
                )
                try await row.create(on: app.db)
                row.createdAt = base.addingTimeInterval(createdOffset)
                row.deletedAt = deletedOffset.map { base.addingTimeInterval($0) }
                try await row.save(on: app.db)
            }

            try await insert("m1", createdOffset: 10)
            try await insert("m2", createdOffset: 20)
            try await insert("m3", createdOffset: 30)
            try await insert("old-deleted", createdOffset: 1, deletedOffset: 25)

            let firstPage = try await MessageRepository.recent(limit: 2, since: base, on: app.db)
            #expect(firstPage.map(\.discordMessageId) == ["m1", "m2"])

            let secondPage = try await MessageRepository.recent(
                limit: 2,
                since: base.addingTimeInterval(20),
                on: app.db
            )
            #expect(secondPage.map(\.discordMessageId) == ["old-deleted", "m3"])
        }
    }

    @Test func compoundMessageCursorDrains501RowsWithIdenticalTimestamp() async throws {
        try await withRuntime { app, _ in
            let sharedStamp = Date(timeIntervalSince1970: 1_700_000_000)
            for index in 0...500 {
                let id = String(format: "m-%04d", index)
                let row = GuildMessage(
                    discordMessageId: id,
                    channelId: "c1",
                    guildId: "g1",
                    authorId: "u1",
                    content: id
                )
                try await row.create(on: app.db)
                row.createdAt = sharedStamp
                try await row.save(on: app.db)
            }

            let first = try await MessageRepository.recent(
                limit: 500,
                cursor: .initial,
                on: app.db
            )
            #expect(first.count == 500)
            #expect(first.first?.discordMessageId == "m-0000")
            #expect(first.last?.discordMessageId == "m-0499")

            let boundary = SyncPullCursor(
                changedAt: first.last?.createdAt ?? .distantPast,
                stableID: first.last?.discordMessageId
            )
            let second = try await MessageRepository.recent(
                limit: 500,
                cursor: boundary,
                on: app.db
            )

            #expect(second.map(\.discordMessageId) == ["m-0500"])
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

    @Test func defaultPushURLIsIndependentOfPullURL() {
        let pull = SyncCursorFileStore.defaultURL()
        let push = SyncCursorFileStore.defaultPushURL()
        #expect(pull.lastPathComponent == "cli-sync-cursor")
        #expect(push.lastPathComponent == "cli-sync-push-cursor")
        #expect(pull != push)
    }

    @Test func pushAndPullCursorsDoNotOverwriteEachOther() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-cursor-pair-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pull = SyncCursorFileStore(fileURL: dir.appendingPathComponent("cli-sync-cursor"))
        let push = SyncCursorFileStore(fileURL: dir.appendingPathComponent("cli-sync-push-cursor"))
        let pullStamp = Date(timeIntervalSince1970: 1_000)
        let pushStamp = Date(timeIntervalSince1970: 2_000)
        try pull.saveLastSuccess(pullStamp)
        try push.saveLastSuccess(pushStamp)

        #expect(abs(pull.loadLastSuccess()!.timeIntervalSince1970 - 1_000) < 0.001)
        #expect(abs(push.loadLastSuccess()!.timeIntervalSince1970 - 2_000) < 0.001)
    }

    @Test func failedOutcomePreservesCursorAndSuccessfulNilClearsIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-cursor-outcome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SyncCursorFileStore(fileURL: url)
        let original = Date(timeIntervalSince1970: 1_000)
        try store.saveLastPullSuccess(original)

        try store.applyPullOutcome(nextCursor: Date(timeIntervalSince1970: 2_000), succeeded: false)
        #expect(store.loadLastPullSuccess() == original)

        try store.applyPullOutcome(nextCursor: nil, succeeded: true)
        #expect(store.loadLastPullSuccess() == nil)
    }

    @Test func legacyPullFileMigratesToAllEntityCursors() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-cursor-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try "1700000000.0".write(to: url, atomically: true, encoding: .utf8)

        let cursors = SyncCursorFileStore(fileURL: url).loadPullCursors()

        for entity in SyncPullEntity.allCases {
            #expect(cursors[entity] == SyncPullCursor(
                changedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ))
        }
    }

    @Test func compoundPullFileRoundTripsIndependentEntityProgress() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-cursor-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SyncCursorFileStore(fileURL: url)
        let expected = SyncPullCursorSet(
            channels: SyncPullCursor(changedAt: Date(timeIntervalSince1970: 200), stableID: "g:c"),
            interactions: SyncPullCursor(changedAt: Date(timeIntervalSince1970: 300), stableID: UUID().uuidString)
        )

        try store.applyPullOutcome(nextCursors: expected, succeeded: true)

        #expect(store.loadPullCursors() == expected)
    }

    @Test func releasedFlatV2FixtureSurvivesCLICursorStoreUpgrade() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-cursor-flat-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"channels":{"changedAt":123,"stableID":"g:c"},"interactions":{"changedAt":456,"stableID":"i-0500"}}"#.utf8)
            .write(to: url, options: .atomic)

        let cursors = SyncCursorFileStore(fileURL: url).loadPullCursors()

        #expect(cursors[.channels] == SyncPullCursor(
            changedAt: Date(timeIntervalSinceReferenceDate: 123),
            stableID: "g:c"
        ))
        #expect(cursors[.interactions] == SyncPullCursor(
            changedAt: Date(timeIntervalSinceReferenceDate: 456),
            stableID: "i-0500"
        ))
    }

    @Test func retiredTransientDictionaryFixtureDegradesCLIStoreToFullBootstrapPull() throws {
        // The dev-only `values` representation is no longer decoded. A file holding one
        // degrades to an empty cursor set (full bootstrap pull) — it is not misread as a
        // legacy epoch cursor either.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-cursor-transient-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"values":["channels",{"changedAt":123,"stableID":"g:c"}]}"#.utf8)
            .write(to: url, options: .atomic)

        let store = SyncCursorFileStore(fileURL: url)

        #expect(store.loadPullCursors() == SyncPullCursorSet())
        #expect(store.loadLastPullSuccess() == nil)
    }

    @Test func endpointNamespacesProduceStableIndependentFiles() {
        let first = SyncCursorFileStore.namespacedPullURL(endpoint: "HTTPS://Example.com:443/api/")
        let equivalent = SyncCursorFileStore.namespacedPullURL(endpoint: "https://example.com/api")
        let other = SyncCursorFileStore.namespacedPullURL(endpoint: "https://other.example/api")

        #expect(first == equivalent)
        #expect(first != other)
        #expect(first.deletingLastPathComponent() == SyncCursorFileStore.defaultURL().deletingLastPathComponent())
    }
}
