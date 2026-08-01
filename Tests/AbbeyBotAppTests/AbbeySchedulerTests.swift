import AbbeyCore
import Foundation
import SwiftData
import Testing
@testable import AbbeyBotApp

@Suite("AbbeyScheduler channel consolidation")
struct AbbeySchedulerTests {
    @Test func consolidationPreservesCountsAboveSummaryWindow() async throws {
        let schema = Schema([
            GuildMessage.self,
            UserMemory.self,
            ChannelContext.self,
            ReputationEvent.self,
            InteractionLog.self,
            EquityIdea.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let seed = ModelContext(container)
        seed.insert(ChannelContext(channelId: "c", guildId: "g", messageCount: 60))
        for index in 0..<60 {
            seed.insert(
                GuildMessage(
                    discordMessageId: "m-\(index)",
                    channelId: "c",
                    guildId: "g",
                    authorId: "u",
                    content: "message \(index)",
                    createdAt: Date(timeIntervalSince1970: Double(index))
                )
            )
        }
        try seed.save()

        let scheduler = AbbeyScheduler(
            modelContainer: container,
            eventBus: EventBus(),
            metrics: EngineMetrics(),
            cooldownSeconds: { 1 },
            consolidationIntervalMinutes: { 60 }
        )
        await scheduler.consolidateAllChannels()

        let verify = ModelContext(container)
        let stored = try #require(try verify.fetch(FetchDescriptor<ChannelContext>()).first)
        #expect(stored.messageCount == 60)
        #expect(stored.summary.contains("message 59"))
        #expect(!stored.summary.contains("message 0"))
    }
}
