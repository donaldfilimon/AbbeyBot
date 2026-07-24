import AbbeyCore
import DiscordBM
import Fluent
import Foundation
import Vapor

/// Headless engine: Fluent persistence + DiscordBM gateway + AbbeyCore brain.
actor BotRuntime {
    let app: Application
    let config: AppConfig
    let metrics: EngineMetrics
    let eventBus: EventBus
    let socialBrain: FluentSocialBrain
    let dqnAgent: DQNAgent
    let scheduler: FluentScheduler
    let personaRouter: ABIRouter
    let inferenceRouter: InferenceRouter
    let discordBridge = DiscordBridge()

    private(set) var discordState: DiscordConnectionState = .disconnected
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
        self.dqnAgent = DQNAgent(topology: [8, 32, 16, 3])
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

    func start() async {
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
        guard !token.isEmpty else {
            app.logger.warning("DISCORD_BOT_TOKEN empty — HTTP API only; Discord gateway not started")
            return
        }
        await connectDiscord(token: token)
    }

    func stop() async {
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

        await bridge.connect(token: token, hooks: hooks, presenceActivityName: "AbbeyServer")
        discordState = await bridge.state
        discordLastError = await bridge.lastError
        discordBotUserId = await bridge.botUserId

        let guild = ProcessInfo.processInfo.environment["DISCORD_DEV_GUILD_ID"]
            ?? config.discordDevGuildId
        if let client = await bridge.client {
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

    func ingestMessage(
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

    func metricsSnapshot() -> MetricsDTO {
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
                let persona = await self.personaRouter.currentPersona()
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
                let persona = await self.personaRouter.currentPersona()
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
            }
        )
    }
}

extension Application {
    private struct BotRuntimeKey: StorageKey {
        typealias Value = BotRuntime
    }

    var botRuntime: BotRuntime {
        get {
            guard let runtime = storage[BotRuntimeKey.self] else {
                fatalError("BotRuntime not configured")
            }
            return runtime
        }
        set { storage[BotRuntimeKey.self] = newValue }
    }
}
