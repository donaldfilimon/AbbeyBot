import AbbeyCore
import Foundation
import SwiftData
import Testing
@testable import AbbeyBotApp

@Suite("SocialBrain reputation commit integrity")
struct SocialBrainTests {
    private struct ForcedSaveFailure: LocalizedError {
        var errorDescription: String? { "forced reputation save failure" }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([UserMemory.self, ReputationEvent.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func failedUpdateKeepsCacheAndStoreAtLastCommittedValueAndPublishesNothing() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(
            UserMemory(
                discordUserId: "user",
                guildId: "guild",
                reputation: 0.7,
                interactionCount: 4
            )
        )
        try seed.save()

        let bus = EventBus()
        let stream = await bus.subscribe()
        let brain = SocialBrain(
            modelContainer: container,
            eventBus: bus,
            decay: { 0.5 },
            saveContext: { _ in throw ForcedSaveFailure() }
        )
        await brain.warmCache()

        await brain.recordInteraction(
            userId: "user",
            guildId: "guild",
            quality: 1.0,
            reason: "test"
        )

        #expect(await brain.reputation(userId: "user", guildId: "guild") == 0.7)
        #expect(await brain.lastPersistenceError?.localizedDescription == "forced reputation save failure")

        let verify = ModelContext(container)
        let users = try verify.fetch(FetchDescriptor<UserMemory>())
        #expect(users.count == 1)
        #expect(users.first?.reputation == 0.7)
        #expect(users.first?.interactionCount == 4)
        #expect(try verify.fetch(FetchDescriptor<ReputationEvent>()).isEmpty)

        await bus.publish(.personaSwitched(to: "sentinel"))
        var iterator = stream.makeAsyncIterator()
        guard let event = await iterator.next() else {
            Issue.record("Expected sentinel event")
            return
        }
        guard case .personaSwitched(let name) = event else {
            Issue.record("A reputationChanged event was published before the failed save")
            return
        }
        #expect(name == "sentinel")
    }

    @Test func failedInsertLeavesNoManagedRowsAndKeepsDefaultCacheValue() async throws {
        let container = try makeContainer()
        let bus = EventBus()
        let stream = await bus.subscribe()
        let brain = SocialBrain(
            modelContainer: container,
            eventBus: bus,
            decay: { 0.5 },
            saveContext: { _ in throw ForcedSaveFailure() }
        )

        await brain.penalize(userId: "new-user", guildId: "guild", reason: "test")

        #expect(
            await brain.reputation(userId: "new-user", guildId: "guild")
                == ReputationMath.defaultScore
        )
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<UserMemory>()).isEmpty)
        #expect(try verify.fetch(FetchDescriptor<ReputationEvent>()).isEmpty)

        await bus.publish(.personaSwitched(to: "sentinel"))
        var iterator = stream.makeAsyncIterator()
        guard let event = await iterator.next() else {
            Issue.record("Expected sentinel event")
            return
        }
        guard case .personaSwitched = event else {
            Issue.record("A reputationChanged event was published before the failed save")
            return
        }
    }

    @Test func successfulSaveCommitsCacheStoreAuditAndEventTogether() async throws {
        let container = try makeContainer()
        let bus = EventBus()
        let stream = await bus.subscribe()
        let brain = SocialBrain(modelContainer: container, eventBus: bus, decay: { 0.5 })

        await brain.recordInteraction(
            userId: "user",
            guildId: "guild",
            quality: 1.0,
            reason: "helpful"
        )

        let expected = ReputationMath.blend(
            current: ReputationMath.defaultScore,
            quality: 1.0,
            decay: 0.5
        )
        #expect(await brain.reputation(userId: "user", guildId: "guild") == expected)
        #expect(await brain.lastPersistenceError == nil)

        let verify = ModelContext(container)
        let user = try #require(try verify.fetch(FetchDescriptor<UserMemory>()).first)
        #expect(user.reputation == expected)
        #expect(user.interactionCount == 1)
        let audit = try #require(try verify.fetch(FetchDescriptor<ReputationEvent>()).first)
        #expect(audit.delta == expected - ReputationMath.defaultScore)
        #expect(audit.reason == "helpful")

        var iterator = stream.makeAsyncIterator()
        guard let event = await iterator.next() else {
            Issue.record("Expected reputationChanged event")
            return
        }
        guard case .reputationChanged(let userId, let guildId, let newValue, let reason) = event else {
            Issue.record("Expected reputationChanged event")
            return
        }
        #expect(userId == "user")
        #expect(guildId == "guild")
        #expect(newValue == expected)
        #expect(reason == "helpful")
    }
}
