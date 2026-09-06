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
        #expect(hits[0].record.payload["contentPreview"] == nil)
    }

    @Test func wdbxV1MigrationPhysicallyScrubsSensitivePayload() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-v1-scrub-\(UUID().uuidString)", isDirectory: true)
        let segments = dir.appendingPathComponent("segments", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let secret = "private legacy message"
        let record = WDBXRecord(
            id: "legacy",
            vector: [1, 0, 0],
            payload: ["guildId": "g", "contentPreview": secret]
        )
        try encoder.encode(WDBXManifest(version: 1, dimension: 3, segmentCount: 1, recordCount: 1))
            .write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        var line = try encoder.encode(record)
        line.append(0x0A)
        try line.write(to: segments.appendingPathComponent("seg-0000.jsonl"), options: .atomic)

        let reopened = try WDBXStore(root: dir, dimension: 3)
        let hit = try #require(reopened.search(query: [1, 0, 0], guildId: "g", limit: 1).first)
        #expect(hit.record.payload["contentPreview"] == nil)
        #expect(reopened.manifestSnapshot.version == 2)

        let segmentURLs = try FileManager.default.contentsOfDirectory(
            at: segments,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }
        let persistedText = try segmentURLs
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        #expect(!persistedText.contains("contentPreview"))
        #expect(!persistedText.contains(secret))
    }

    @Test func immediateHeuristicRewardIsTerminalBanditExperience() async throws {
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-bandit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let agent = DQNAgent(epsilon: 0, seed: 7, experienceJournalURL: journalURL)

        let result = await IngestScorer.scoreAndLearn(
            content: "How do I configure this?",
            guildId: "g",
            reputationBefore: 0.5,
            authorInteractionCount: 1,
            channelMessageCount: 2,
            dqnAgent: agent
        )

        let persisted = try #require(try ExperienceJournal(url: journalURL).loadRecent(limit: 1).first)
        #expect(persisted.done)
        #expect(persisted.state == result.state)
        #expect(persisted.nextState == result.state)
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

    @Test func wdbxEncodingFailureDoesNotPublishOrConsumeSegmentSlots() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-encode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try WDBXStore(root: dir, dimension: 1, maxRecordsPerSegment: 100)
        try store.upsert(WDBXRecord(id: "same", vector: [1], payload: ["guildId": "g"]))
        let before = store.recent()
        let manifest = store.manifestSnapshot
        for id in ["same", "new"] {
            #expect(throws: EncodingError.self) {
                try store.upsert(WDBXRecord(id: id, vector: [.nan], payload: ["guildId": "g"]))
            }
        }
        #expect(store.recent() == before)
        #expect(store.manifestSnapshot == manifest)
        for _ in 1..<100 {
            try store.upsert(WDBXRecord(id: "same", vector: [1], payload: ["guildId": "g"]))
        }
        #expect(store.manifestSnapshot.segmentCount == 1)
        let reopened = try WDBXStore(root: dir, dimension: 1)
        #expect(reopened.recent().map(\.id) == ["same"])
    }

    @Test func wdbxSegmentWriteFailurePreservesCacheAndManifest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try WDBXStore(root: dir, dimension: 1, maxRecordsPerSegment: 100)
        for _ in 0..<100 {
            try store.upsert(WDBXRecord(id: "same", vector: [1], payload: [:]))
        }
        let before = store.recent()
        let manifest = store.manifestSnapshot
        let blockedSegment = dir.appendingPathComponent("segments/seg-0001.jsonl")
        try FileManager.default.createDirectory(at: blockedSegment, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try store.upsert(WDBXRecord(id: "same", vector: [2], payload: [:]))
        }
        #expect(store.recent() == before)
        #expect(store.manifestSnapshot == manifest)
        try FileManager.default.removeItem(at: blockedSegment)
        try store.upsert(WDBXRecord(id: "same", vector: [3], payload: [:]))
        let reopened = try WDBXStore(root: dir, dimension: 1)
        #expect(reopened.recent().first?.vector == [3])
        #expect(reopened.manifestSnapshot.segmentCount == 2)
    }

    @Test(arguments: [false, true])
    func wdbxReopenRepairsInterruptedTailBeforeAppending(withCommittedPrefix: Bool) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-tail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = dir.appendingPathComponent("segments/seg-0000.jsonl")
        do {
            let store = try WDBXStore(root: dir, dimension: 1)
            if withCommittedPrefix {
                try store.upsert(WDBXRecord(id: "before", vector: [1], payload: [:]))
            }
        }
        let prefix = try (withCommittedPrefix ? Data(contentsOf: segment) : Data())
        var interrupted = prefix
        interrupted.append(contentsOf: #"{"id":"interrupted","payload":{"text":""#.utf8)
        interrupted.append(0xC3) // Interrupted UTF-8, not just incomplete JSON.
        try interrupted.write(to: segment)

        let reopened = try WDBXStore(root: dir, dimension: 1)
        #expect(try Data(contentsOf: segment) == prefix)
        #expect(reopened.recordCount == (withCommittedPrefix ? 1 : 0))
        try reopened.upsert(WDBXRecord(id: "after", vector: [2], payload: [:]))
        let again = try WDBXStore(root: dir, dimension: 1)
        #expect(again.recent().map(\.id) == (withCommittedPrefix ? ["after", "before"] : ["after"]))
        #expect(again.manifestSnapshot.recordCount == (withCommittedPrefix ? 2 : 1))
    }

    @Test func wdbxReopenPreservesCompleteLegacyTailWithoutNewline() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-legacy-tail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let segment = dir.appendingPathComponent("segments/seg-0000.jsonl")
        do {
            let store = try WDBXStore(root: dir, dimension: 1)
            try store.upsert(WDBXRecord(id: "legacy", vector: [1], payload: [:]))
        }
        let terminated = try Data(contentsOf: segment)
        try Data(terminated.dropLast()).write(to: segment)
        let reopened = try WDBXStore(root: dir, dimension: 1)
        #expect(reopened.recent().map(\.id) == ["legacy"])
        #expect(try Data(contentsOf: segment) == terminated)
        try reopened.upsert(WDBXRecord(id: "after", vector: [2], payload: [:]))
        let again = try WDBXStore(root: dir, dimension: 1)
        #expect(again.recent().map(\.id) == ["after", "legacy"])
    }

    @Test func wdbxManifestFailureRetainsCommittedLogAndRepairsOnReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try WDBXStore(root: dir, dimension: 1)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let staleManifest = try Data(contentsOf: manifestURL)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
        // A nonempty directory reliably prevents atomic replacement, even as root.
        try Data().write(to: manifestURL.appendingPathComponent("blocker"))
        #expect(throws: (any Error).self) {
            try store.upsert(WDBXRecord(id: "committed", vector: [1], payload: [:]))
        }
        #expect(store.recent().map(\.id) == ["committed"])
        #expect(store.manifestSnapshot.recordCount == 1)
        try FileManager.default.removeItem(at: manifestURL)
        try staleManifest.write(to: manifestURL)
        let reopened = try WDBXStore(root: dir, dimension: 1)
        #expect(reopened.recent().map(\.id) == ["committed"])
        #expect(reopened.manifestSnapshot.recordCount == 1)
        #expect(reopened.manifestSnapshot.segmentCount == 1)
    }

    @Test func dqnRejectsInvalidLiveAndReplayedExperiences() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-dqn-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journalURL = dir.appendingPathComponent("experience.jsonl")
        let journal = ExperienceJournal(url: journalURL)
        let agent = DQNAgent(topology: [2, 4], epsilon: 0, seed: 7, experienceJournalURL: journalURL)
        let valid = Experience(state: [0.5, 1], action: 0, reward: 1, nextState: [1, 0.5], done: false)
        let invalid = [
            Experience(state: [0.5, 1], action: -1, reward: 1, nextState: [1, 0.5], done: false),
            Experience(state: [0.5, 1], action: 4, reward: 1, nextState: [1, 0.5], done: false),
            Experience(state: [1], action: 0, reward: 1, nextState: [1, 0.5], done: false),
            Experience(state: [1, 2, 3], action: 0, reward: 1, nextState: [1, 0.5], done: false),
            Experience(state: [0.5, 1], action: 0, reward: 1, nextState: [1], done: true),
            Experience(state: [0.5, 1], action: 0, reward: 1, nextState: [1, 2, 3], done: false),
        ]
        let before = await agent.online
        for experience in invalid {
            await agent.remember(experience)
            try journal.append(experience)
        }
        for scalar in [Float.nan, .infinity, -.infinity] {
            await agent.remember(Experience(state: [scalar, 1], action: 0, reward: 1, nextState: [1, 1], done: false))
            await agent.remember(Experience(state: [1, 1], action: 0, reward: scalar, nextState: [1, 1], done: false))
            await agent.remember(Experience(state: [1, 1], action: 0, reward: 1, nextState: [scalar, 1], done: true))
        }
        #expect(await agent.bufferCount() == 0)
        let journalBytes = try Data(contentsOf: journalURL)
        try await agent.loadExperienceJournalIfPresent()
        #expect(await agent.bufferCount() == 0)
        #expect(try Data(contentsOf: journalURL) == journalBytes)
        await agent.learn(batchSize: 0)
        await agent.learn(batchSize: -1)
        await agent.learn(batchSize: 1)
        #expect(await agent.stepCount == 0)
        #expect(await agent.online.weights == before.weights)
        #expect(await agent.online.biases == before.biases)

        await agent.remember(valid)
        #expect(try journal.loadRecent().count == invalid.count + 1)
        let control = DQNAgent(topology: [2, 4], epsilon: 0, seed: 7)
        await control.remember(valid)
        await agent.learn(batchSize: 1)
        await control.learn(batchSize: 1)
        let expected = await control.online
        #expect(await agent.online.weights == expected.weights)
        #expect(await agent.online.biases == expected.biases)
        #expect(await agent.stepCount == 1)
        let replayed = DQNAgent(topology: [2, 4], epsilon: 0, seed: 7, experienceJournalURL: journalURL)
        try await replayed.loadExperienceJournalIfPresent()
        #expect(await replayed.bufferCount() == 1)
        await replayed.learn(batchSize: 1)
        #expect(await replayed.online.weights == expected.weights)
        #expect(await replayed.online.biases == expected.biases)
    }

    @Test func dqnInvalidSelectionDoesNotChangeReceiptOrRandomSequence() async {
        let agent = DQNAgent(topology: [2, 4], epsilon: 1, seed: 7)
        let control = DQNAgent(topology: [2, 4], epsilon: 1, seed: 7)
        let invalidStates: [[Float]] = [[], [1], [1, 2, 3], [.nan, 1], [1, .infinity]]
        for state in invalidStates {
            #expect(await agent.selectAction(state: state) == 0)
        }
        #expect(await agent.lastQValues.isEmpty)
        #expect(await agent.lastStrategy == .answer)
        let expected = await control.selectAction(state: [1, 1])
        #expect(await agent.selectAction(state: [1, 1]) == expected)
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

        // Existing hosts may still supply both legacy inputs during migration. The
        // facade wins as the one owner instead of appending twice to the same file.
        let legacyURL = dir.appendingPathComponent("legacy.jsonl")
        let legacyMemory = WDBXMemoryFacade(journalURL: legacyURL)
        let legacyAgent = DQNAgent(
            experienceJournalURL: legacyURL,
            wdbxFacade: legacyMemory
        )
        await legacyAgent.remember(
            Experience(state: state, action: 1, reward: 0.5, nextState: state, done: false)
        )
        #expect(try ExperienceJournal(url: legacyURL).loadRecent().count == 1)
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
