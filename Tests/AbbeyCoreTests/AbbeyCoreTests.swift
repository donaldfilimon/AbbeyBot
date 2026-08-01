import Foundation
import Testing
@testable import AbbeyCore

@Suite("AbbeyCore engine")
struct AbbeyCoreTests {
    @Test func intentClassification() {
        #expect(IntentClassifier.classify("hello there") == .greeting)
        #expect(IntentClassifier.classify("what is up?") == .question)
        #expect(IntentClassifier.classify("remember tea") == .memoryStore)
        #expect(IntentClassifier.classify("please kick that user") == .modRequest)
        #expect(IntentClassifier.classify("be aviva please") == .personaSwitch)
        #expect(IntentClassifier.classify("be abi") == .personaSwitch)
        #expect(IntentClassifier.classify("switch to abbey") == .personaSwitch)
        #expect(IntentClassifier.classify("🔥") == .unknown)
        #expect(IntentClassifier.classifyLoose("🔥") == .smallTalk)
        #expect(IntentClassifier.classifyStrict("🔥") == .unknown)
    }

    @Test func discordCopyStrings() {
        #expect(DiscordCopy.engineUnavailable == "Engine unavailable.")
        #expect(DiscordCopy.noMemory == "No memory for that user.")
        #expect(DiscordCopy.invalidFactIndex == "Invalid fact index.")
        #expect(DiscordCopy.noChannelSummary == "No channel summary yet.")
        #expect(DiscordCopy.reputation(userId: "u1", value: 0.5) == "Reputation for u1: 0.500")
        #expect(DiscordCopy.remembered(userId: "u1") == "Remembered for u1.")
        #expect(DiscordCopy.forgot(index: 2) == "Forgot fact #2.")
        #expect(DiscordCopy.switchedPersona("Abbey") == "Switched to Abbey.")
        struct SampleError: Error {}
        #expect(DiscordCopy.forgetFailed(SampleError()).contains("Failed to forget:"))
        #expect(DiscordCopy.rememberFailed(SampleError()).contains("Failed to remember:"))
    }

    @Test func operatorFacingErrorPrefersLocalizedDescription() {
        struct Plain: Error {}
        struct Localized: Error, LocalizedError {
            var errorDescription: String? { "localized boom" }
        }
        #expect(OperatorFacingError.message(Localized()) == "localized boom")
        #expect(!OperatorFacingError.message(Plain()).isEmpty)
    }

    @Test func interactionCommandLabelFormatting() {
        #expect(InteractionCommandLabel.format("remember") == "/remember")
        #expect(InteractionCommandLabel.format("persona.abbey") == "persona.abbey")
        #expect(InteractionCommandLabel.format("ingestMessage") == "ingestMessage")
        #expect(InteractionCommandLabel.format("/voice") == "/voice")
    }

    @Test func discordVoiceCopyNeverClaimsAudio() {
        let joined = DiscordCopy.voiceJoined(channelId: "c1")
        let left = DiscordCopy.voiceLeft(guildId: "g1")
        let idle = DiscordCopy.voiceStatus(guildId: nil, channelId: nil)
        let active = DiscordCopy.voiceStatus(guildId: "g1", channelId: "c1")
        for sample in [
            joined, left, idle, active,
            DiscordCopy.voicePresenceOnly,
            DiscordCopy.voiceUnknownSubcommand,
            DiscordCopy.voiceDryRunNoGateway
        ] {
            #expect(sample.localizedCaseInsensitiveContains("no audio") || sample.localizedCaseInsensitiveContains("presence only"))
            #expect(!sample.localizedCaseInsensitiveContains("listening to you"))
            #expect(!sample.localizedCaseInsensitiveContains("playing audio"))
        }
        #expect(joined.contains("c1"))
        #expect(left.contains("g1"))
        #expect(active.contains("c1") && active.contains("g1"))
        #expect(VoiceAction.join(channelId: "x") == .join(channelId: "x"))
        #expect(VoiceAction.leave == .leave)
    }

    @Test func voicePresenceMapsOutcomesWithoutDuplicatingEngineLogic() async {
        let notConnected = await VoicePresence.perform(
            .join(channelId: "c1"),
            guildId: "g1",
            isConnected: false,
            gatewayReady: false,
            join: { _, _ in .requested },
            leave: { _ in .requested }
        )
        #expect(notConnected == DiscordCopy.voiceNotConnected)

        let dryRunNoGateway = await VoicePresence.perform(
            .join(channelId: "c1"),
            guildId: "g1",
            isConnected: true,
            gatewayReady: false,
            join: { _, _ in .requested },
            leave: { _ in .requested }
        )
        #expect(dryRunNoGateway == DiscordCopy.voiceDryRunNoGateway)

        let missingGuild = await VoicePresence.perform(
            .leave,
            guildId: "DM",
            isConnected: true,
            gatewayReady: true,
            join: { _, _ in .requested },
            leave: { _ in .requested }
        )
        #expect(missingGuild == DiscordCopy.voiceMissingGuild)

        let joined = await VoicePresence.perform(
            .join(channelId: "c9"),
            guildId: "g9",
            isConnected: true,
            gatewayReady: true,
            join: { guild, channel in
                #expect(guild == "g9")
                #expect(channel == "c9")
                return .requested
            },
            leave: { _ in .gatewayUnavailable }
        )
        #expect(joined == DiscordCopy.voiceJoined(channelId: "c9"))

        let badIdsOnJoin = await VoicePresence.perform(
            .join(channelId: "c1"),
            guildId: "g1",
            isConnected: true,
            gatewayReady: true,
            join: { _, _ in .invalidIdentifiers },
            leave: { _ in .requested }
        )
        #expect(badIdsOnJoin == DiscordCopy.voiceMissingChannel)

        let leaveFailed = await VoicePresence.perform(
            .leave,
            guildId: "g1",
            isConnected: true,
            gatewayReady: true,
            join: { _, _ in .requested },
            leave: { _ in .gatewayUnavailable }
        )
        #expect(leaveFailed == DiscordCopy.voiceLeaveFailed)

        #expect(VoiceUpdateResult.requested == .requested)
        #expect(VoiceUpdateResult.gatewayUnavailable != .invalidIdentifiers)
    }

    @Test func intentQualityAndSuggestions() {
        #expect(IntentClassifier.Intent.question.quality == 0.8)
        #expect(IntentClassifier.Intent.unknown.quality == 0.2)
        #expect(IntentClassifier.Intent.greeting.quality == 0.5)
        #expect(IntentClassifier.Intent.command.quality == 0.6)
        #expect(IntentClassifier.classify("/help") == .command)
        #expect(IntentClassifier.suggestCompletions(for: "what") == [
            "what do you think about",
            "what is the reputation of"
        ])
        #expect(IntentClassifier.suggestCompletions(for: "zzz").isEmpty)
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
        #expect(CommandRegistry.all.count == 17)
        #expect(CommandRegistry.all.contains(where: { $0.name == "voice" }))
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
        #expect(PersonaName.resolve("be abi") == "Abi")
        #expect(PersonaName.resolve("abbey") == "Abbey")
        #expect(PersonaName.resolve("average day") == "Abbey")
        #expect(PersonaName.resolve("capability") == "Abbey")
    }

    @Test func abiRouterRoutesByFrameworkRoles() async {
        let bus = EventBus()
        let router = ABIRouter(eventBus: bus)
        #expect(await router.route(intent: .modRequest).name == "Abi")
        #expect(await router.route(intent: .command).name == "Abi")
        #expect(await router.route(intent: .question).name == "Aviva")
        #expect(await router.route(intent: .greeting).name == "Abbey")
        #expect(await router.route(intent: .smallTalk).name == "Abbey")
        #expect(await router.route(intent: .unknown).name == "Abbey")
        #expect(await router.currentPersona().name == "Abbey")
        await router.setPersona(named: "aviva")
        #expect(await router.route(intent: .unknown).name == "Aviva")
    }

    @Test func naturalPersonaSwitchIsRequestScoped() async {
        let router = ABIRouter(eventBus: EventBus())
        await router.setPersona(named: "aviva")

        #expect(await router.route(intent: .personaSwitch, userText: "switch to abi").name == "Abi")
        #expect(await router.currentPersona().name == "Aviva")
        #expect(IntentClassifier.classify("How does a Swift switch statement work?") == .question)
        #expect(IntentClassifier.classify("switch to abi") == .personaSwitch)
        #expect(IntentClassifier.classify("be abbey please") == .personaSwitch)
    }

    @Test func memoryFactExtract() {
        #expect(MemoryFactText.extract(from: "remember tea") == "tea")
        #expect(MemoryFactText.extract(from: "Note that likes jazz") == "likes jazz")
        #expect(MemoryFactText.extract(from: "remember   ") == "")
        #expect(MemoryFactText.extract(from: "REMEMBER Caps") == "Caps")
    }

    @Test func replyCooldownTracker() {
        var tracker = ReplyCooldownTracker()
        #expect(tracker.isCoolingDown(userId: "u", guildId: "g", cooldownSeconds: 8) == false)
        tracker.markReplied(userId: "u", guildId: "g")
        #expect(tracker.isCoolingDown(userId: "u", guildId: "g", cooldownSeconds: 8) == true)
        #expect(tracker.isCoolingDown(userId: "other", guildId: "g", cooldownSeconds: 8) == false)
    }

    @Test func channelSummaryBuilderOrder() {
        #expect(ChannelSummaryBuilder.summarize([]) == "")
        let text = ChannelSummaryBuilder.summarize([
            .init(authorId: "a", content: "one"),
            .init(authorId: "b", content: "two")
        ])
        #expect(text == "a: one\nb: two")
        let long = String(repeating: "x", count: 200)
        let truncated = ChannelSummaryBuilder.summarize([
            .init(authorId: "a", content: long)
        ], maxContentChars: 10)
        #expect(truncated == "a: xxxxxxxxxx")
    }

    @Test func ingestScorerLatencyNonNegative() {
        let started = ContinuousClock.now
        let ms = IngestScorer.latencyMilliseconds(since: started)
        #expect(ms >= 0)
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

    @Test func appConfigValidateLiveDiscordRequiresToken() throws {
        let suite = "AbbeyCoreTests.validate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let config = AppConfig(defaults: defaults)
        config.operatingMode = .liveDiscord
        config.dryRun = false
        config.discordBotToken = ""
        #expect(throws: AppConfigValidationError.self) {
            try config.validateForStartup()
        }
        config.dryRun = true
        try config.validateForStartup()
        // Headless must not fail on desktop liveDiscord-without-token leftovers.
        config.dryRun = false
        config.discordBotToken = ""
        try config.validateForStartup(scope: .headless)
    }

    @Test func appConfigValidateRemoteEndpoint() throws {
        let suite = "AbbeyCoreTests.remote.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let config = AppConfig(defaults: defaults)
        config.inferenceMode = .remoteCompatible
        config.remoteEndpoint = ""
        #expect(throws: AppConfigValidationError.self) {
            try config.validateForStartup()
        }
        config.remoteEndpoint = "https://example.com/v1"
        try config.validateForStartup()
    }

    @Test func appConfigEnvOverridesUserDefaultsInference() throws {
        let suite = "AbbeyCoreTests.envInference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(InferenceMode.remoteCompatible.rawValue, forKey: "ABBEY_INFERENCE_MODE")
        defaults.set("", forKey: "ABBEY_REMOTE_ENDPOINT")
        let config = AppConfig(
            defaults: defaults,
            environment: [
                "ABBEY_INFERENCE_MODE": "deterministicFloor",
                "ABBEY_REMOTE_ENDPOINT": "https://env.example/v1",
            ]
        )
        #expect(config.inferenceMode == .deterministicFloor)
        #expect(config.remoteEndpoint == "https://env.example/v1")
        try config.validateForStartup(scope: .headless)
    }

    @Test func dqnCheckpointRoundTripPreservesGreedyAction() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-dqn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ckpt.json")
        let agent = DQNAgent(topology: [8, 32, 16, 3], epsilon: 0, seed: 99, checkpointURL: url)
        await agent.setEpsilonForTesting(0)
        let state: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        let actionBefore = await agent.selectAction(state: state)
        try await agent.save(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let restored = DQNAgent(topology: [8, 32, 16, 3], epsilon: 0.5, seed: 1, checkpointURL: url)
        try await restored.load(from: url)
        await restored.setEpsilonForTesting(0)
        let actionAfter = await restored.selectAction(state: state)
        #expect(actionAfter == actionBefore)

        try Data("not-json".utf8).write(to: url)
        do {
            try await restored.load(from: url)
            Issue.record("expected corrupt checkpoint to throw")
        } catch is DQNCheckpointError {
            // expected
        }
    }

    @Test func experienceJournalAppendAndReload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("exp.jsonl")
        let journal = ExperienceJournal(url: url)
        let exp = Experience(
            state: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
            action: 1,
            reward: 0.5,
            nextState: [0.2, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
            done: true
        )
        try journal.append(exp)
        try journal.append(exp)
        let loaded = try journal.loadRecent(limit: 10)
        #expect(loaded.count == 2)
        #expect(loaded[0].action == 1)

        let agent = DQNAgent(
            topology: [8, 32, 16, 3],
            experienceJournalURL: url
        )
        await agent.remember(exp)
        let again = try ExperienceJournal(url: url).loadRecent()
        #expect(again.count >= 3)
    }

    @Test func codeProposalValidatorRejectsShellAndAcceptsSafeSwift() {
        #expect(CodeProposalValidator.validate("func hello() -> String { \"hi\" }") == .accepted)
        if case .rejected(let reasons) = CodeProposalValidator.validate("let p = Process(); p.executableURL = URL(fileURLWithPath: \"/bin/sh\")") {
            #expect(!reasons.isEmpty)
        } else {
            Issue.record("expected Process proposal to reject")
        }
        if case .rejected = CodeProposalValidator.validate("URLSession.shared.data(from: url)") {
            // ok
        } else {
            Issue.record("expected URLSession.data to reject")
        }
        #expect(throws: CodeProposalRejection.self) {
            try CodeProposalValidator.acceptOrThrow("rm -rf /tmp/x")
        }
    }

    @Test func rollbackStoreSnapshotAndRestore() throws {
        let abbey = try RollbackStore.abbeyHome()
        let live = abbey.appendingPathComponent("rollback-test-\(UUID().uuidString).txt")
        try Data("v1".utf8).write(to: live)
        defer { try? FileManager.default.removeItem(at: live) }
        let snapName = "test-\(UUID().uuidString)"
        _ = try RollbackStore.snapshot(file: live, as: snapName)
        try Data("v2".utf8).write(to: live)
        try RollbackStore.restore(file: live, fromSnapshot: snapName)
        #expect(String(data: try Data(contentsOf: live), encoding: .utf8) == "v1")

        try Data("v3".utf8).write(to: live)
        let bak = live.appendingPathExtension("bak")
        try Data("from-bak".utf8).write(to: bak)
        defer { try? FileManager.default.removeItem(at: bak) }
        try RollbackStore.restoreFromBak(live)
        #expect(String(data: try Data(contentsOf: live), encoding: .utf8) == "from-bak")

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("not-abbey.txt")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(throws: RollbackStore.Error.self) {
            try RollbackStore.snapshot(file: outside, as: "nope")
        }
    }

    @Test func twitchBridgeDryRunConnectsWithoutSocket() async {
        let bridge = TwitchBridge()
        await bridge.connect(oauthToken: "oauth:fake", login: "abbeybot", channel: "test", dryRun: true)
        #expect(await bridge.state == .connected)
        #expect(await bridge.loginNick == "abbeybot")
        await bridge.disconnect()
        #expect(await bridge.state == .disconnected)
    }

    @Test func twitchIRCParserPrivmsg() {
        let line = ":alice!alice@alice.tmi.twitch.tv PRIVMSG #mychan :hello world"
        let msg = TwitchIRCParser.parsePrivmsg(line)
        #expect(msg?.channel == "mychan")
        #expect(msg?.login == "alice")
        #expect(msg?.text == "hello world")
        let tagged = "@badge-info=;badges= :bob!bob@bob.tmi.twitch.tv PRIVMSG #x :hi"
        #expect(TwitchIRCParser.parsePrivmsg(tagged)?.login == "bob")
        #expect(TwitchIRCParser.parsePrivmsg("PING :tmi.twitch.tv") == nil)
    }

    @Test func industryProfilePromptSuffixes() {
        #expect(IndustryProfile.general.promptSuffix.isEmpty)
        #expect(!IndustryProfile.healthcare.promptSuffix.isEmpty)
        #expect(IndustryProfile.resolve("FINANCE") == .finance)
        #expect(IndustryProfile.resolve("nope") == .general)
    }

    @Test func wdbxMemoryFacadeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbey-wdbx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("j.jsonl")
        let facade = WDBXMemoryFacade(journalURL: url)
        let exp = Experience(
            state: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
            action: 0,
            reward: 1,
            nextState: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8],
            done: true
        )
        try facade.remember(exp)
        #expect(try facade.recent(limit: 5).count == 1)
    }

    @Test func decentralizationPolicyRejectsEnabled() {
        #expect(throws: DecentralizationPolicy.ValidationError.self) {
            try DecentralizationPolicy(enabled: true).validate()
        }
        try! DecentralizationPolicy.disabled.validate()
    }

    @Test func discordBridgeDryRunSkipsGateway() async {
        let bridge = DiscordBridge()
        await bridge.connect(token: "", hooks: DiscordEventHooks(), dryRun: true)
        #expect(await bridge.state == .connected)
        #expect(await bridge.botUserId == "dry-run")
        #expect(await bridge.client == nil)
    }
}
