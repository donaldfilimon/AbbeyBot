import Foundation
import SwiftData
import Testing
@testable import AbbeyBotApp

@Suite("SyncPull conflict resolution")
struct SyncPullTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            GuildMessage.self,
            UserMemory.self,
            ChannelContext.self,
            ReputationEvent.self,
            InteractionLog.self,
            EquityIdea.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    @Test func upsertUsersPreservesNewerLocalEditOverOlderRemote() throws {
        let context = try makeContext()
        let local = UserMemory(discordUserId: "u1", guildId: "g1", facts: ["local fact"], reputation: 0.9, updatedAt: Date())
        local.compositeKey = "g1:u1"
        context.insert(local)
        try context.save()

        let remote = SyncDTO.User(
            id: UUID(),
            compositeKey: "g1:u1",
            discordUserId: "u1",
            guildId: "g1",
            facts: ["stale remote fact"],
            reputation: 0.5,
            interactionCount: 0,
            updatedAt: Date().addingTimeInterval(-100)
        )

        try SyncPull.upsertUsers([remote], into: context)

        let key = "g1:u1"
        let descriptor = FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })
        let stored = try context.fetch(descriptor).first
        #expect(stored?.reputation == 0.9)
        #expect(stored?.facts == ["local fact"])
    }

    @Test func upsertUsersAppliesNewerRemoteEditOverOlderLocal() throws {
        let context = try makeContext()
        let local = UserMemory(discordUserId: "u1", guildId: "g1", facts: ["stale local fact"], reputation: 0.5, updatedAt: Date().addingTimeInterval(-100))
        local.compositeKey = "g1:u1"
        context.insert(local)
        try context.save()

        let remote = SyncDTO.User(
            id: UUID(),
            compositeKey: "g1:u1",
            discordUserId: "u1",
            guildId: "g1",
            facts: ["fresh remote fact"],
            reputation: 0.9,
            interactionCount: 3,
            updatedAt: Date()
        )

        try SyncPull.upsertUsers([remote], into: context)

        let key = "g1:u1"
        let descriptor = FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })
        let stored = try context.fetch(descriptor).first
        #expect(stored?.reputation == 0.9)
        #expect(stored?.facts == ["fresh remote fact"])
        #expect(stored?.interactionCount == 3)
    }

    @Test func upsertChannelsPreservesNewerLocalEditOverOlderRemote() throws {
        let context = try makeContext()
        let local = ChannelContext(channelId: "c1", guildId: "g1", summary: "local summary", messageCount: 10, updatedAt: Date())
        local.compositeKey = "g1:c1"
        context.insert(local)
        try context.save()

        let remote = SyncDTO.Channel(
            id: UUID(),
            compositeKey: "g1:c1",
            channelId: "c1",
            guildId: "g1",
            summary: "stale remote summary",
            messageCount: 1,
            updatedAt: Date().addingTimeInterval(-100)
        )

        try SyncPull.upsertChannels([remote], into: context)

        let key = "g1:c1"
        let descriptor = FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.compositeKey == key })
        let stored = try context.fetch(descriptor).first
        #expect(stored?.summary == "local summary")
        #expect(stored?.messageCount == 10)
    }

    @Test func upsertUsersAppliesTombstoneByHardDeletingLocalRow() throws {
        let context = try makeContext()
        let local = UserMemory(discordUserId: "u1", guildId: "g1", facts: ["gone"], reputation: 0.5, updatedAt: Date().addingTimeInterval(-100))
        local.compositeKey = "g1:u1"
        context.insert(local)
        try context.save()

        let deletedAt = Date()
        let remote = SyncDTO.User(
            id: UUID(),
            compositeKey: "g1:u1",
            discordUserId: "u1",
            guildId: "g1",
            facts: ["gone"],
            reputation: 0.5,
            interactionCount: 0,
            updatedAt: deletedAt,
            deletedAt: deletedAt
        )

        try SyncPull.upsertUsers([remote], into: context)

        let key = "g1:u1"
        let descriptor = FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })
        #expect(try context.fetch(descriptor).isEmpty)
    }

    @Test func upsertUsersPreservesNewerLocalEditOverOlderTombstone() throws {
        let context = try makeContext()
        let local = UserMemory(discordUserId: "u1", guildId: "g1", facts: ["kept"], reputation: 0.9, updatedAt: Date())
        local.compositeKey = "g1:u1"
        context.insert(local)
        try context.save()

        let deletedAt = Date().addingTimeInterval(-100)
        let remote = SyncDTO.User(
            id: UUID(),
            compositeKey: "g1:u1",
            discordUserId: "u1",
            guildId: "g1",
            facts: [],
            reputation: 0.1,
            interactionCount: 0,
            updatedAt: deletedAt,
            deletedAt: deletedAt
        )

        try SyncPull.upsertUsers([remote], into: context)

        let key = "g1:u1"
        let descriptor = FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })
        #expect(try context.fetch(descriptor).first?.facts == ["kept"])
    }

    @Test func upsertChannelsAppliesTombstoneByHardDeletingLocalRow() throws {
        let context = try makeContext()
        let local = ChannelContext(channelId: "c1", guildId: "g1", summary: "gone", messageCount: 3, updatedAt: Date().addingTimeInterval(-50))
        local.compositeKey = "g1:c1"
        context.insert(local)
        try context.save()

        let deletedAt = Date()
        let remote = SyncDTO.Channel(
            id: UUID(),
            compositeKey: "g1:c1",
            channelId: "c1",
            guildId: "g1",
            summary: "gone",
            messageCount: 3,
            updatedAt: deletedAt,
            deletedAt: deletedAt
        )

        try SyncPull.upsertChannels([remote], into: context)

        let key = "g1:c1"
        let descriptor = FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.compositeKey == key })
        #expect(try context.fetch(descriptor).isEmpty)
    }

    @Test func upsertEquityAppliesTombstoneByHardDeletingLocalRow() throws {
        let context = try makeContext()
        let local = EquityIdea(
            symbol: "QX-DEL",
            thesisSummary: "gone",
            syntheticScore: 0.2,
            factorBreakdown: ["x": 0.2],
            generatedAt: Date().addingTimeInterval(-20)
        )
        context.insert(local)
        try context.save()

        // Soft-delete keeps the original generatedAt; tombstone stamp is deletedAt.
        let generatedAt = Date().addingTimeInterval(-20)
        let deletedAt = Date()
        let remote = SyncDTO.Equity(
            id: UUID(),
            symbol: "QX-DEL",
            thesisSummary: "gone",
            syntheticScore: 0.2,
            factorBreakdown: ["x": 0.2],
            generatedAt: generatedAt,
            deletedAt: deletedAt
        )

        try SyncPull.upsertEquity([remote], into: context)

        let symbol = "QX-DEL"
        let descriptor = FetchDescriptor<EquityIdea>(predicate: #Predicate { $0.symbol == symbol })
        #expect(try context.fetch(descriptor).isEmpty)
    }

    @Test func insertMissingMessagesAppliesTombstoneByHardDeletingLocalRow() throws {
        let context = try makeContext()
        context.insert(
            GuildMessage(
                discordMessageId: "m-del",
                channelId: "c1",
                guildId: "g1",
                authorId: "u1",
                content: "bye",
                createdAt: Date().addingTimeInterval(-30)
            )
        )
        try context.save()

        let deletedAt = Date()
        let remote = SyncDTO.Message(
            id: UUID(),
            discordMessageId: "m-del",
            channelId: "c1",
            guildId: "g1",
            authorId: "u1",
            content: "bye",
            createdAt: Date().addingTimeInterval(-30),
            deletedAt: deletedAt
        )

        try SyncPull.insertMissingMessages([remote], into: context)

        let mid = "m-del"
        let descriptor = FetchDescriptor<GuildMessage>(predicate: #Predicate { $0.discordMessageId == mid })
        #expect(try context.fetch(descriptor).isEmpty)
    }

    // MARK: - Equity
    //
    // Equity ideas are regenerated rather than hand-edited, so `generatedAt` is the
    // comparable timestamp: the more recently *generated* idea for a symbol wins.

    @Test func upsertEquityPreservesNewerLocalIdeaOverOlderRemote() throws {
        let context = try makeContext()
        let local = EquityIdea(
            symbol: "QX-4471",
            thesisSummary: "fresh local thesis",
            syntheticScore: 0.9,
            factorBreakdown: ["momentum": 0.9],
            generatedAt: Date()
        )
        context.insert(local)
        try context.save()

        let remote = SyncDTO.Equity(
            id: UUID(),
            symbol: "QX-4471",
            thesisSummary: "stale remote thesis",
            syntheticScore: 0.1,
            factorBreakdown: ["momentum": 0.1],
            generatedAt: Date().addingTimeInterval(-100)
        )

        try SyncPull.upsertEquity([remote], into: context)

        let symbol = "QX-4471"
        let descriptor = FetchDescriptor<EquityIdea>(predicate: #Predicate { $0.symbol == symbol })
        let stored = try context.fetch(descriptor).first
        #expect(stored?.thesisSummary == "fresh local thesis")
        #expect(stored?.syntheticScore == 0.9)
    }

    @Test func upsertEquityAppliesNewerRemoteIdeaOverOlderLocal() throws {
        let context = try makeContext()
        let local = EquityIdea(
            symbol: "QX-4471",
            thesisSummary: "stale local thesis",
            syntheticScore: 0.1,
            factorBreakdown: ["momentum": 0.1],
            generatedAt: Date().addingTimeInterval(-100)
        )
        context.insert(local)
        try context.save()

        let remote = SyncDTO.Equity(
            id: UUID(),
            symbol: "QX-4471",
            thesisSummary: "fresh remote thesis",
            syntheticScore: 0.9,
            factorBreakdown: ["momentum": 0.9],
            generatedAt: Date()
        )

        try SyncPull.upsertEquity([remote], into: context)

        let symbol = "QX-4471"
        let descriptor = FetchDescriptor<EquityIdea>(predicate: #Predicate { $0.symbol == symbol })
        let stored = try context.fetch(descriptor).first
        #expect(stored?.thesisSummary == "fresh remote thesis")
        #expect(stored?.syntheticScore == 0.9)
    }

    @Test func upsertEquityInsertsUnseenSymbol() throws {
        let context = try makeContext()
        let remote = SyncDTO.Equity(
            id: UUID(),
            symbol: "QX-9999",
            thesisSummary: "new idea",
            syntheticScore: 0.5,
            factorBreakdown: ["value": 0.5],
            generatedAt: Date()
        )

        try SyncPull.upsertEquity([remote], into: context)

        let symbol = "QX-9999"
        let descriptor = FetchDescriptor<EquityIdea>(predicate: #Predicate { $0.symbol == symbol })
        #expect(try context.fetch(descriptor).first?.thesisSummary == "new idea")
    }
}
