import AbbeyCore
import DiscordBM
import Fluent
import Foundation
import Vapor

public struct MetricsDTO: Content {
    public var messagesIngested: Int
    public var reputationEvents: Int
    public var consolidations: String
    public var inferenceCalls: Int
    public var inferenceFailures: Int
    public var liveIngestCount: Int
    public var discordState: String
    public var discordBotUserId: String
    public var lastInferenceError: String

    public init(
        messagesIngested: Int,
        reputationEvents: Int,
        consolidations: String,
        inferenceCalls: Int,
        inferenceFailures: Int,
        liveIngestCount: Int,
        discordState: String,
        discordBotUserId: String,
        lastInferenceError: String
    ) {
        self.messagesIngested = messagesIngested
        self.reputationEvents = reputationEvents
        self.consolidations = consolidations
        self.inferenceCalls = inferenceCalls
        self.inferenceFailures = inferenceFailures
        self.liveIngestCount = liveIngestCount
        self.discordState = discordState
        self.discordBotUserId = discordBotUserId
        self.lastInferenceError = lastInferenceError
    }
}

public struct UserStateDTO: Content {
    public var facts: [String]
    public var reputation: Double

    public init(facts: [String], reputation: Double) {
        self.facts = facts
        self.reputation = reputation
    }
}

public struct ChannelStateDTO: Content {
    public var summary: String

    public init(summary: String) {
        self.summary = summary
    }
}

/// Headless engine: Fluent persistence + DiscordBM gateway + AbbeyCore brain.
public actor BotRuntime {
    let app: Application
    let config: AppConfig
    let metrics: EngineMetrics
    public let eventBus: EventBus
    let socialBrain: FluentSocialBrain
    let dqnAgent: DQNAgent
    let scheduler: FluentScheduler
    let personaRouter: ABIRouter
    let inferenceRouter: InferenceRouter
    let discordBridge = DiscordBridge()

    public private(set) var discordState: DiscordConnectionState = .disconnected
    private(set) var discordLastError: String?
    private(set) var discordBotUserId: String?
    private(set) var liveIngestCount: Int = 0
    private var metricsListener: Task<Void, Never>?

    init(app: Application) {
        self.app = app
        let config = AppConfig.shared
        self.config = config
        let metrics = EngineMetrics()
        self.metrics = metrics
        let bus = EventBus()
        self.eventBus = bus
        self.socialBrain = FluentSocialBrain(db: app.db, eventBus: bus, decay: { config.reputationDecay })
        let checkpointURL = try? DQNCheckpointStore.defaultURL()
        self.dqnAgent = DQNAgent(topology: [8, 32, 16, 3], checkpointURL: checkpointURL)
        self.scheduler = FluentScheduler(
            db: app.db,
            logger: app.logger,
            eventBus: bus,
            metrics: metrics,
            cooldownSeconds: { config.replyCooldownSeconds },
            consolidationIntervalMinutes: { config.memoryConsolidationIntervalMinutes }
        )
        self.personaRouter = ABIRouter(eventBus: bus)
        self.inferenceRouter = InferenceRouter(
            eventBus: bus,
            metrics: metrics,
            currentMode: { config.inferenceMode },
            remoteEndpoint: { config.remoteEndpoint }
        )
    }

    public func start() async {
        do {
            try await dqnAgent.loadCheckpointIfPresent()
        } catch {
            app.logger.warning(
                "DQN checkpoint load failed: \(OperatorFacingError.message(error)) — using fresh weights"
            )
        }
        await socialBrain.warmCache()
        await scheduler.start()
        metricsListener = Task { [weak self] in
            guard let self else { return }
            let stream = await self.eventBus.subscribe()
            for await event in stream {
                await self.handle(event)
            }
        }

        let token = ProcessInfo.processInfo.environment["DISCORD_BOT_TOKEN"]
            ?? config.discordBotToken
        if config.dryRun {
            await connectDiscord(token: token.isEmpty ? "dry-run" : token)
            return
        }
        guard !token.isEmpty else {
            app.logger.warning("DISCORD_BOT_TOKEN empty — HTTP API only; Discord gateway not started")
            return
        }
        await connectDiscord(token: token)
    }

    public func stop() async {
        metricsListener?.cancel()
        metricsListener = nil
        await scheduler.stop()
        await discordBridge.disconnect()
        discordState = .disconnected
    }

    private func handle(_ event: AbbeyEvent) {
        switch event {
        case .messageIngested:
            metrics.recordMessageIngested()
        case .reputationChanged:
            metrics.recordReputationEvent()
        case .inferenceProviderFailed(_, let message):
            metrics.recordInferenceFailureMessage(message)
        default:
            break
        }
    }

    func connectDiscord(token: String) async {
        discordState = .connecting
        discordLastError = nil
        let ingress = makeMessageIngress()
        let interactions = makeInteractionRouter()
        let bridge = discordBridge

        let hooks = DiscordEventHooks(
            onReady: { [weak self] userId in
                guard let self else { return }
                await self.noteReady(userId: userId)
            },
            onMessageCreate: { message in
                guard let client = await bridge.client else { return }
                await ingress.handle(message, client: client)
            },
            onInteractionCreate: { interaction in
                guard let client = await bridge.client else { return }
                await interactions.handle(interaction, client: client)
            }
        )

        await bridge.connect(
            token: token,
            hooks: hooks,
            presenceActivityName: "AbbeyServer",
            dryRun: config.dryRun
        )
        discordState = await bridge.state
        discordLastError = await bridge.lastError
        discordBotUserId = await bridge.botUserId

        let guild = ProcessInfo.processInfo.environment["DISCORD_DEV_GUILD_ID"]
            ?? config.discordDevGuildId
        if !config.dryRun, let client = await bridge.client {
            do {
                try await CommandRegistry.register(client: client, guildId: guild.isEmpty ? nil : guild)
                app.logger.info("Slash commands registered")
            } catch {
                app.logger.warning("Slash command registration failed: \(error)")
            }
        }
    }

    private func noteReady(userId: String) {
        discordBotUserId = userId
        discordState = .connected
    }

    public func ingestMessage(
        content: String,
        channelId: String,
        guildId: String,
        authorId: String,
        discordMessageId: String
    ) async {
        let started = ContinuousClock.now
        do {
            try await MessageRepository.insert(
                discordMessageId: discordMessageId,
                channelId: channelId,
                guildId: guildId,
                authorId: authorId,
                content: content,
                on: app.db
            )
            liveIngestCount += 1
            try await ChannelRepository.bump(channelId: channelId, guildId: guildId, on: app.db)

            let intent = IntentClassifier.classify(content)
            if intent == .memoryStore {
                let fact = MemoryFactText.extract(from: content)
                try await MemoryRepository.appendFact(userId: authorId, guildId: guildId, fact: fact, on: app.db)
            }
            if intent == .personaSwitch {
                await personaRouter.setPersona(named: PersonaName.resolve(content))
            }

            await eventBus.publish(.messageIngested(channelId: channelId, guildId: guildId, authorId: authorId))

            let reputationBefore = await socialBrain.reputation(userId: authorId, guildId: guildId)
            let authorInteractionCount = try await UserMemory.query(on: app.db)
                .filter(\.$discordUserId == authorId)
                .filter(\.$guildId == guildId)
                .first()?.interactionCount ?? 0
            let channelActivity = try await ChannelRepository.messageCount(
                channelId: channelId,
                guildId: guildId,
                on: app.db
            )

            let scored = await IngestScorer.scoreAndLearn(
                content: content,
                guildId: guildId,
                reputationBefore: reputationBefore,
                authorInteractionCount: authorInteractionCount,
                channelMessageCount: channelActivity,
                dqnAgent: dqnAgent,
                intent: intent
            )
            await socialBrain.recordInteraction(userId: authorId, guildId: guildId, quality: scored.quality)

            try await InteractionRepository.log(
                commandName: "ingestMessage",
                userId: authorId,
                guildId: guildId,
                succeeded: true,
                latencyMs: IngestScorer.latencyMilliseconds(since: started),
                on: app.db
            )
        } catch {
            app.logger.error("ingest failed: \(error)")
        }
    }

    func personaContext(authorId: String, guildId: String, channelId: String) async -> PersonaContext {
        let summary = (try? await ChannelRepository.summary(channelId: channelId, guildId: guildId, on: app.db)) ?? ""
        let facts = (try? await MemoryRepository.facts(userId: authorId, guildId: guildId, on: app.db)) ?? []
        let reputation = await socialBrain.reputation(userId: authorId, guildId: guildId)
        return PersonaContext(channelSummary: summary, userFacts: facts, reputation: reputation)
    }

    /// Persona reply to free text, outside the Discord message/interaction flow — used by
    /// the CLI's conversation loop, mirroring `makeInteractionRouter`'s `ask` closure.
    public func reply(to text: String, userId: String, guildId: String, channelId: String) async -> String {
        let intent = IntentClassifier.classify(text)
        let persona = await personaRouter.route(intent: intent)
        let context = await personaContext(authorId: userId, guildId: guildId, channelId: channelId)
        return await persona.respond(to: text, context: context, inference: inferenceRouter).text
    }

    /// Keyed read of a user's shared state — used by the desktop app's sync client
    /// (and anything else that needs facts/reputation without a channel in hand).
    public func userState(userId: String, guildId: String) async -> UserStateDTO {
        let facts = (try? await MemoryRepository.facts(userId: userId, guildId: guildId, on: app.db)) ?? []
        let reputation = await socialBrain.reputation(userId: userId, guildId: guildId)
        return UserStateDTO(facts: facts, reputation: reputation)
    }

    /// Keyed read of a channel's shared state (summary only — message count is
    /// available via `/api/channels`).
    public func channelState(channelId: String, guildId: String) async -> ChannelStateDTO {
        let summary = (try? await ChannelRepository.summary(channelId: channelId, guildId: guildId, on: app.db)) ?? ""
        return ChannelStateDTO(summary: summary)
    }

    /// Direct remember, outside the "remember ..." intent-classification round-trip —
    /// used by the desktop app's sync client and anything else with a fact in hand already.
    public func remember(userId: String, guildId: String, fact: String) async throws {
        try await MemoryRepository.appendFact(userId: userId, guildId: guildId, fact: fact, on: app.db)
    }

    /// Direct forget by 1-based fact index (same indexing as the `/forget` slash command).
    public func forget(userId: String, guildId: String, index: Int) async throws {
        try await MemoryRepository.forgetFact(userId: userId, guildId: guildId, index: index, on: app.db)
    }

    public func metricsSnapshot() -> MetricsDTO {
        MetricsDTO(
            messagesIngested: metrics.messagesIngestedThisSession,
            reputationEvents: metrics.reputationEventsThisSession,
            consolidations: metrics.lastConsolidationAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            inferenceCalls: metrics.totalInferenceCalls,
            inferenceFailures: metrics.totalInferenceFailures,
            liveIngestCount: liveIngestCount,
            discordState: discordState.rawValue,
            discordBotUserId: discordBotUserId ?? "",
            lastInferenceError: metrics.lastInferenceFailureMessage ?? ""
        )
    }

    private func makeMessageIngress() -> MessageIngress {
        MessageIngress(
            ingest: { [weak self] content, channelId, guildId, authorId, messageId in
                guard let self else { return }
                await self.ingestMessage(
                    content: content,
                    channelId: channelId,
                    guildId: guildId,
                    authorId: authorId,
                    discordMessageId: messageId
                )
            },
            craftReply: { [weak self] content, channelId, guildId, authorId in
                guard let self else { return nil }
                let intent = IntentClassifier.classify(content)
                let persona = await self.personaRouter.route(intent: intent)
                let context = await self.personaContext(authorId: authorId, guildId: guildId, channelId: channelId)
                let response = await persona.respond(to: content, context: context, inference: self.inferenceRouter)
                return response.text
            },
            isCoolingDown: { [weak self] userId, guildId in
                guard let self else { return false }
                return await self.scheduler.isCoolingDown(userId: userId, guildId: guildId)
            },
            markReplied: { [weak self] userId, guildId in
                guard let self else { return }
                await self.scheduler.markReplied(userId: userId, guildId: guildId)
            },
            botUserId: { [weak self] in
                await self?.discordBridge.botUserId
            }
        )
    }

    private func makeInteractionRouter() -> InteractionRouter {
        InteractionRouter(
            ask: { [weak self] question, userId, guildId, channelId in
                guard let self else { return DiscordCopy.engineUnavailable }
                let persona = await self.personaRouter.route(intent: .question)
                let context = await self.personaContext(authorId: userId, guildId: guildId, channelId: channelId)
                return await persona.respond(to: question, context: context, inference: self.inferenceRouter).text
            },
            rep: { [weak self] userId, guildId in
                guard let self else { return DiscordCopy.engineUnavailable }
                let value = await self.socialBrain.reputation(userId: userId, guildId: guildId)
                return DiscordCopy.reputation(userId: userId, value: value)
            },
            remember: { [weak self] userId, guildId, fact in
                guard let self else { return DiscordCopy.engineUnavailable }
                do {
                    try await MemoryRepository.appendFact(userId: userId, guildId: guildId, fact: fact, on: self.app.db)
                    return DiscordCopy.remembered(userId: userId)
                } catch {
                    return DiscordCopy.rememberFailed(error)
                }
            },
            forget: { [weak self] userId, guildId, index in
                guard let self else { return DiscordCopy.engineUnavailable }
                do {
                    try await MemoryRepository.forgetFact(
                        userId: userId,
                        guildId: guildId,
                        index: index,
                        on: self.app.db
                    )
                    return DiscordCopy.forgot(index: index)
                } catch MemoryForgetError.noMemory {
                    return DiscordCopy.noMemory
                } catch MemoryForgetError.invalidIndex {
                    return DiscordCopy.invalidFactIndex
                } catch {
                    return DiscordCopy.forgetFailed(error)
                }
            },
            context: { [weak self] channelId, guildId in
                guard let self else { return DiscordCopy.engineUnavailable }
                let summary = (try? await ChannelRepository.summary(
                    channelId: channelId,
                    guildId: guildId,
                    on: self.app.db
                )) ?? ""
                return summary.isEmpty ? DiscordCopy.noChannelSummary : summary
            },
            persona: { [weak self] name in
                guard let self else { return DiscordCopy.engineUnavailable }
                let mapped = PersonaName.resolve(name)
                await self.personaRouter.setPersona(named: mapped)
                return DiscordCopy.switchedPersona(mapped)
            },
            voice: { [weak self] action, guildId in
                guard let self else { return DiscordCopy.engineUnavailable }
                return await self.performVoice(action, guildId: guildId)
            }
        )
    }

    private func performVoice(_ action: VoiceAction, guildId: String) async -> String {
        let bridge = discordBridge
        return await VoicePresence.perform(
            action,
            guildId: guildId,
            isConnected: await bridge.state == .connected,
            gatewayReady: await bridge.hasGateway,
            join: { guild, channel in await bridge.joinVoice(guildId: guild, channelId: channel) },
            leave: { guild in await bridge.leaveVoice(guildId: guild) }
        )
    }
}

extension Application {
    private struct BotRuntimeKey: StorageKey {
        typealias Value = BotRuntime
    }

    public var botRuntime: BotRuntime {
        get {
            guard let runtime = storage[BotRuntimeKey.self] else {
                fatalError("BotRuntime not configured")
            }
            return runtime
        }
        set { storage[BotRuntimeKey.self] = newValue }
    }
}
