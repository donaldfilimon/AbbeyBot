import Testing
@testable import AbbeyCore

@Suite("AbbeyCore engine")
struct AbbeyCoreTests {
    @Test func intentClassification() {
        #expect(IntentClassifier.classify("hello there") == .greeting)
        #expect(IntentClassifier.classify("what is up?") == .question)
        #expect(IntentClassifier.classify("remember tea") == .memoryStore)
        #expect(IntentClassifier.classify("please kick that user") == .modRequest)
        #expect(IntentClassifier.classify("🔥") == .unknown)
        #expect(IntentClassifier.classifyLoose("🔥") == .smallTalk)
        #expect(IntentClassifier.classifyStrict("🔥") == .unknown)
    }

    @Test func discordCopyStrings() {
        #expect(DiscordCopy.forgot(index: 2) == "Forgot fact #2.")
        #expect(DiscordCopy.switchedPersona("Abbey") == "Switched to Abbey.")
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

    @Test func reputationMathBlendAndPenalty() {
        let blended = ReputationMath.blend(current: 0.5, quality: 1.0, decay: 0.9)
        #expect(abs(blended - 0.55) < 0.0001)
        #expect(ReputationMath.penalize(current: 0.05) == 0)
        #expect(ReputationMath.cacheKey(userId: "u", guildId: "g") == "g:u")
        #expect(ReputationMath.channelKey(channelId: "c", guildId: "g") == "g:c")
        #expect(ReputationMath.compositeKey(guildId: "g", id: "x") == "g:x")
    }

    @Test func personaNameResolveConsistent() {
        #expect(PersonaName.resolve("aviva") == "Aviva")
        #expect(PersonaName.resolve("AV") == "Aviva")
        #expect(PersonaName.resolve("be aviva please") == "Aviva")
        #expect(PersonaName.resolve("abi") == "Abi")
        #expect(PersonaName.resolve("abbey") == "Abbey")
    }

    @Test func memoryFactExtract() {
        #expect(MemoryFactText.extract(from: "remember tea") == "tea")
        #expect(MemoryFactText.extract(from: "Note that likes jazz") == "likes jazz")
    }

    @Test func replyCooldownTracker() {
        var tracker = ReplyCooldownTracker()
        #expect(tracker.isCoolingDown(userId: "u", guildId: "g", cooldownSeconds: 8) == false)
        tracker.markReplied(userId: "u", guildId: "g")
        #expect(tracker.isCoolingDown(userId: "u", guildId: "g", cooldownSeconds: 8) == true)
    }

    @Test func channelSummaryBuilderOrder() {
        let text = ChannelSummaryBuilder.summarize([
            .init(authorId: "a", content: "one"),
            .init(authorId: "b", content: "two")
        ])
        #expect(text == "a: one\nb: two")
    }

    @Test func ingestScorerRunsDQNStep() async {
        let agent = DQNAgent(topology: [8, 32, 16, 3])
        let scored = await IngestScorer.scoreAndLearn(
            content: "hello abbey",
            guildId: "g",
            reputationBefore: 0.5,
            authorInteractionCount: 2,
            channelMessageCount: 10,
            dqnAgent: agent
        )
        #expect(scored.action >= 0 && scored.action < 3)
        #expect(scored.quality >= 0)
    }
}
