import Testing
@testable import AbbeyCore

@Suite("AbbeyCore engine")
struct AbbeyCoreTests {
    @Test func intentClassification() {
        #expect(IntentClassifier.classify("hello there") == .greeting)
        #expect(IntentClassifier.classify("what is up?") == .question)
        #expect(IntentClassifier.classify("remember tea") == .memoryStore)
        #expect(IntentClassifier.classify("please kick that user") == .modRequest)
        #expect(IntentClassifier.classifyStrict("🔥") == .unknown)
    }

    @Test func sentimentProjection() {
        let state = SentimentAnalyzer.analyze(
            text: "GREAT stuff!",
            authorReputation: 0.7,
            recentReactionCount: 2,
            mentionsSomeone: true,
            isReply: false,
            timestamp: .now,
            channelMessageCountInWindow: 10,
            authorInteractionCount: 3,
            isDirectMessage: false
        )
        #expect(state.count == 18)
        let projected = SentimentAnalyzer.projectToNetworkInput(state)
        #expect(projected.count == 8)
        #expect(projected[7] == 1.0)
    }

    @Test func factorScreenClamps() {
        let low = FactorScreen.score(.init(momentum: -1, volatilityDampening: 0, syntheticGrowth: -1, noveltyPenalty: 1))
        let high = FactorScreen.score(.init(momentum: 1, volatilityDampening: 1, syntheticGrowth: 1, noveltyPenalty: 0))
        #expect(low >= 0 && low <= 1)
        #expect(high >= 0 && high <= 1)
    }

    @Test func deterministicFloorGreeting() async throws {
        let floor = DeterministicFloorProvider()
        let result = try await floor.generate(InferenceRequest(systemPrompt: "x", userText: "hey", contextLines: []))
        #expect(result.mode == .deterministicFloor)
        #expect(result.text == "Hey.")
    }

    @Test func confirmationGateCancel() async {
        let bus = EventBus()
        let gate = ConfirmationGate(eventBus: bus, requireConfirmation: { true })
        let task = Task {
            await gate.request(kind: .kick, targetUserId: "u", guildId: "g", reason: "t")
        }
        try? await Task.sleep(for: .milliseconds(30))
        let queue = await gate.queue
        #expect(queue.count == 1)
        if let id = queue.first?.id {
            await gate.cancel(id)
        }
        let approved = await task.value
        #expect(approved == false)
    }

    @Test func commandRegistryNonEmpty() {
        #expect(CommandRegistry.all.count == 6)
    }
}
