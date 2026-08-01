import Foundation
import Testing
@testable import AbbeyCore

@Suite("Strategy + WDBX + accelerated neural self-learn")
struct SelfLearnWDBXTests {
    @Test func defaultTopologyIsFourStrategies() {
        #expect(DQNAgent.defaultTopology.last == StrategyAction.allCases.count)
        #expect(StrategyAction.from(raw: 2) == .retrieve)
        #expect(StrategyAction.from(raw: 99) == .answer)
    }

    @Test func shapedRewardPrefersRefuseOnMod() {
        let refuse = StrategyAction.refuse.shapedReward(intent: .modRequest, quality: 0.8)
        let answer = StrategyAction.answer.shapedReward(intent: .modRequest, quality: 0.8)
        #expect(refuse > answer)
    }

    @Test func wdbxStoreUpsertAndSearch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try WDBXStore(root: dir, dimension: SentimentAnalyzer.stateDimension)
        var vector = [Float](repeating: 0, count: SentimentAnalyzer.stateDimension)
        vector[0] = 1
        vector[4] = 0.5
        try store.upsert(
            WDBXRecord(
                id: "r1",
                vector: vector,
                payload: [
                    "contentPreview": "hello world",
                    "kind": "ingest",
                    "guildId": "g1",
                ]
            )
        )
        #expect(store.recordCount == 1)
        let hits = store.search(query: vector, guildId: "g1", limit: 3)
        #expect(!hits.isEmpty)
        #expect(hits[0].record.id == "r1")
        #expect(hits[0].score > 0.9)
    }

    @Test func wdbxSearchIsGuildScopedAndAppliesSafeSimilarityFloor() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try WDBXStore(root: dir, dimension: 3)
        try store.upsert(
            WDBXRecord(
                id: "guild-a",
                vector: [1, 0, 0],
                payload: ["guildId": "a", "channelId": "c1", "userId": "u1"]
            )
        )
        try store.upsert(
            WDBXRecord(
                id: "guild-b",
                vector: [1, 0, 0],
                payload: ["guildId": "b", "channelId": "c1", "userId": "u1"]
            )
        )
        try store.upsert(
            WDBXRecord(
                id: "weak",
                vector: [0, 1, 0],
                payload: ["guildId": "a", "channelId": "c1", "userId": "u1"]
            )
        )

        let hits = store.search(
            query: [1, 0, 0],
            guildId: "a",
            channelId: "c1",
            userId: "u1",
            minimumSimilarity: -1,
            limit: 10
        )
        #expect(hits.map(\.record.id) == ["guild-a"])
        #expect(store.search(query: [1, 0, 0], guildId: "", limit: 10).isEmpty)
        #expect(store.search(query: [1, 0, 0], guildId: "missing", limit: 10).isEmpty)
    }

    @Test func wdbxReopenDeduplicatesUpsertsWithLastWriteWinning() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-reopen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try WDBXStore(root: dir, dimension: 3)
            try store.upsert(
                WDBXRecord(id: "same", vector: [1, 0, 0], payload: ["guildId": "g", "version": "old"])
            )
            try store.upsert(
                WDBXRecord(id: "same", vector: [0, 1, 0], payload: ["guildId": "g", "version": "new"])
            )
            #expect(store.recordCount == 1)
        }

        let reopened = try WDBXStore(root: dir, dimension: 3)
        #expect(reopened.recordCount == 1)
        #expect(reopened.manifestSnapshot.recordCount == 1)
        let hits = reopened.search(query: [0, 1, 0], guildId: "g", limit: 5)
        #expect(hits.count == 1)
        #expect(hits.first?.record.payload["version"] == "new")
    }

    @Test func neuralMathDotMatchesNaive() {
        let a: [Float] = [0.1, -0.2, 0.3, 0.4, 1.5]
        let b: [Float] = [0.5, 0.5, -0.1, 0.2, 0.0]
        let accelerated = NeuralMath.dot(a, b)
        let naive = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        #expect(abs(accelerated - naive) < 1e-5)
    }

    @Test func dqnSelectsAndRemembersWithFourActions() async {
        let agent = DQNAgent(topology: DQNAgent.defaultTopology, epsilon: 0, seed: 1)
        await agent.setEpsilonForTesting(0)
        let state: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 1.0]
        let action = await agent.selectAction(state: state)
        #expect((0..<4).contains(action))
        let strategy = await agent.lastStrategy
        #expect(StrategyAction.allCases.contains(strategy))
        await agent.remember(
            Experience(state: state, action: action, reward: 0.5, nextState: state.map { $0 * 0.9 }, done: false)
        )
        #expect(await agent.bufferCount() == 1)
        let accel = NeuralMath.accelerationBackend
        #expect(accel.contains("Accelerate") || accel.contains("Swift"))
    }

    @Test func dqnUsesExactlyOneExperiencePersistenceOwner() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-journal-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journalURL = dir.appendingPathComponent("experience.jsonl")
        let memory = WDBXMemoryFacade(journalURL: journalURL)
        let agent = DQNAgent(experiencePersistence: .memory(memory))
        let state = [Float](repeating: 0.25, count: 8)
        await agent.remember(
            Experience(state: state, action: 0, reward: 1, nextState: state, done: true)
        )

        let reloaded = try ExperienceJournal(url: journalURL).loadRecent()
        #expect(reloaded.count == 1)
        #expect(await agent.bufferCount() == 1)
    }

    @Test func corruptCheckpointDoesNotPartiallyMutateAgent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-checkpoint-atomic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let beforeURL = dir.appendingPathComponent("before.json")
        let corruptURL = dir.appendingPathComponent("corrupt.json")
        let afterURL = dir.appendingPathComponent("after.json")
        let agent = DQNAgent(topology: [8, 4], epsilon: 0.2, seed: 77)
        try await agent.save(to: beforeURL)
        let before = try JSONDecoder().decode(
            DQNCheckpointBlob.self,
            from: Data(contentsOf: beforeURL)
        )

        var corrupt = before
        corrupt.onlineWeights[0][0][0] += 100
        corrupt.targetBiases[0].removeLast()
        corrupt.epsilon = 0.9
        corrupt.stepCount = 999
        try JSONEncoder().encode(corrupt).write(to: corruptURL, options: .atomic)

        do {
            try await agent.load(from: corruptURL)
            Issue.record("expected corrupt checkpoint to throw")
        } catch is DQNCheckpointError {
            // Expected: neither candidate network nor scalar state may commit.
        }

        try await agent.save(to: afterURL)
        let after = try JSONDecoder().decode(
            DQNCheckpointBlob.self,
            from: Data(contentsOf: afterURL)
        )
        #expect(after == before)
    }

    @Test func replyDirectiveRetrieveIncludesMemory() {
        let text = StrategyAction.retrieve.replyDirective(
            userText: "what do I like?",
            retrievedFacts: ["likes zig"]
        )
        #expect(text.contains("likes zig"))
        #expect(text.contains("what do I like?"))
    }
}
