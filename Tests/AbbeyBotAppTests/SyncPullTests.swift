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
}
