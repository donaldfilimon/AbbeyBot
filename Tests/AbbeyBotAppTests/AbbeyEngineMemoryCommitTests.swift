import AbbeyCore
import Foundation
import SwiftData
import Testing
@testable import AbbeyBotApp

@MainActor
@Suite("AbbeyEngine memory commit integrity", .serialized)
struct AbbeyEngineMemoryCommitTests {
    private struct SaveFailure: LocalizedError {
        var errorDescription: String? { "injected save failure" }
    }

    private final class PushRecorder {
        var rememberCalls: [(guildId: String, userId: String, fact: String)] = []
        var forgetCalls: [(guildId: String, userId: String, index: Int)] = []
        var saveCompleted = false
        var everyPushObservedCommittedSave = true

        func recordRemember(guildId: String, userId: String, fact: String) {
            everyPushObservedCommittedSave = everyPushObservedCommittedSave && saveCompleted
            rememberCalls.append((guildId, userId, fact))
        }

        func recordForget(guildId: String, userId: String, index: Int) {
            everyPushObservedCommittedSave = everyPushObservedCommittedSave && saveCompleted
            forgetCalls.append((guildId, userId, index))
        }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            GuildMessage.self,
            UserMemory.self,
            ChannelContext.self,
            ReputationEvent.self,
            InteractionLog.self,
            EquityIdea.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func rememberAcknowledgesAndSchedulesPushOnlyAfterCommit() async throws {
        let container = try makeContainer()
        let recorder = PushRecorder()
        let engine = AbbeyEngine(
            modelContainer: container,
            saveModelContext: { context in
                try context.save()
                recorder.saveCompleted = true
            },
            scheduleRememberPush: { guildId, userId, fact in
                recorder.recordRemember(guildId: guildId, userId: userId, fact: fact)
            },
            scheduleForgetPush: { _, _, _ in }
        )

        let response = await engine.rememberFact(userId: "u1", guildId: "g1", fact: "likes tea")

        #expect(response == DiscordCopy.remembered(userId: "u1"))
        #expect(recorder.rememberCalls.count == 1)
        #expect(recorder.rememberCalls.first?.fact == "likes tea")
        #expect(recorder.everyPushObservedCommittedSave)
        let verify = ModelContext(container)
        let key = ReputationMath.cacheKey(userId: "u1", guildId: "g1")
        let stored = try verify.fetch(
            FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })
        ).first
        #expect(stored?.facts == ["likes tea"])

        await engine.shutdown()
    }

    @Test func rememberBoundsFactsAndReportsWhatItDropped() async throws {
        let container = try makeContainer()
        var pushed: [String] = []
        let engine = AbbeyEngine(
            modelContainer: container,
            scheduleRememberPush: { _, _, fact in pushed.append(fact) },
            scheduleForgetPush: { _, _, _ in }
        )
        for i in 1...MemoryFactPolicy.maxFacts {
            _ = await engine.rememberFact(userId: "u1", guildId: "g1", fact: "fact \(i)")
        }
        let long = String(repeating: "z", count: MemoryFactPolicy.maxFactLength + 5)

        let response = await engine.rememberFact(userId: "u1", guildId: "g1", fact: long)

        #expect(response == DiscordCopy.remembered(userId: "u1", truncated: true, evicted: 1))
        #expect(pushed.last?.count == MemoryFactPolicy.maxFactLength)
        let verify = ModelContext(container)
        let key = ReputationMath.cacheKey(userId: "u1", guildId: "g1")
        let stored = try verify.fetch(
            FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })
        ).first
        #expect(stored?.facts.count == MemoryFactPolicy.maxFacts)
        #expect(stored?.facts.first == "fact 2")
        #expect(stored?.facts.last == String(long.prefix(MemoryFactPolicy.maxFactLength)))

        await engine.shutdown()
    }

    @Test func rememberFailureRollsBackAndDoesNotAcknowledgeOrPush() async throws {
        let container = try makeContainer()
        let recorder = PushRecorder()
        let engine = AbbeyEngine(
            modelContainer: container,
            saveModelContext: { _ in throw SaveFailure() },
            scheduleRememberPush: { guildId, userId, fact in
                recorder.recordRemember(guildId: guildId, userId: userId, fact: fact)
            },
            scheduleForgetPush: { _, _, _ in }
        )

        let response = await engine.rememberFact(userId: "u1", guildId: "g1", fact: "likes tea")

        #expect(response.contains("Failed to remember"))
        #expect(response.contains("Nothing was synchronized"))
        #expect(recorder.rememberCalls.isEmpty)
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<UserMemory>()).isEmpty)
        #expect(try verify.fetch(FetchDescriptor<GuildMessage>()).isEmpty)

        await engine.shutdown()
    }

    @Test func forgetAcknowledgesAndSchedulesPushOnlyAfterCommit() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(UserMemory(discordUserId: "u1", guildId: "g1", facts: ["one", "two"]))
        try seed.save()
        let recorder = PushRecorder()
        let engine = AbbeyEngine(
            modelContainer: container,
            saveModelContext: { context in
                try context.save()
                recorder.saveCompleted = true
            },
            scheduleRememberPush: { _, _, _ in },
            scheduleForgetPush: { guildId, userId, index in
                recorder.recordForget(guildId: guildId, userId: userId, index: index)
            }
        )

        let response = engine.forgetFact(userId: "u1", guildId: "g1", index: 1)

        #expect(response == DiscordCopy.forgot(index: 1))
        #expect(recorder.forgetCalls.count == 1)
        #expect(recorder.forgetCalls.first?.index == 1)
        #expect(recorder.everyPushObservedCommittedSave)
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<UserMemory>()).first?.facts == ["two"])

        await engine.shutdown()
    }

    @Test func forgetFailureRollsBackAndDoesNotAcknowledgeOrPush() async throws {
        let container = try makeContainer()
        let seed = ModelContext(container)
        seed.insert(UserMemory(discordUserId: "u1", guildId: "g1", facts: ["one", "two"]))
        try seed.save()
        let recorder = PushRecorder()
        let engine = AbbeyEngine(
            modelContainer: container,
            saveModelContext: { _ in throw SaveFailure() },
            scheduleRememberPush: { _, _, _ in },
            scheduleForgetPush: { guildId, userId, index in
                recorder.recordForget(guildId: guildId, userId: userId, index: index)
            }
        )

        let response = engine.forgetFact(userId: "u1", guildId: "g1", index: 1)

        #expect(response.contains("Failed to forget"))
        #expect(response.contains("injected save failure"))
        #expect(recorder.forgetCalls.isEmpty)
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<UserMemory>()).first?.facts == ["one", "two"])

        await engine.shutdown()
    }
}
