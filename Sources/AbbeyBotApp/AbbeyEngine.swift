import Foundation
import SwiftData
import Observation
import AbbeyCore

/// The single object the SwiftUI layer talks to. Owns the `ModelContainer` and every
/// actor described in the Engine/ and Inference/ folders, and exposes them either
/// directly (for views that just need to pass them to a subview) or through small
/// `@MainActor`-hopping convenience methods views can call straight from a `Button`
/// action or `.task {}` modifier.
@Observable
@MainActor
final class AbbeyEngine {
    let modelContainer: ModelContainer
    let config = AppConfig.shared
    let metrics = EngineMetrics()

    let eventBus: EventBus
    let socialBrain: SocialBrain
    let dqnAgent: DQNAgent
    let scheduler: AbbeyScheduler
    let confirmationGate: ConfirmationGate
    let personaRouter: ABIRouter
    let inferenceRouter: InferenceRouter
    var equityEngine = EquityResearchEngine()

    /// Most recent event received, so SwiftUI views can just observe this property
    /// instead of each subscribing to the raw `AsyncStream` — trades a little
    /// granularity for a much simpler view-layer API. Views that need the full
    /// history should query the relevant SwiftData model directly instead.
    private(set) var lastEvent: AbbeyEvent?
    private(set) var lastDQNAction: Int?
    private(set) var discordState: DiscordConnectionState = .disconnected
    private(set) var discordLastError: String?
    private(set) var discordBotUserId: String?
    private(set) var liveIngestCount: Int = 0

    let discordBridge = DiscordBridge()
    let moderationClient = ModerationClient()
    private var eventListenerTask: Task<Void, Never>?
    private var discordStatusTask: Task<Void, Never>?

    init(modelContainer: ModelContainer, storeDegraded: Bool = false) {
        self.modelContainer = modelContainer

        let bus = EventBus()
        self.eventBus = bus

        let config = AppConfig.shared
        self.socialBrain = SocialBrain(modelContainer: modelContainer, eventBus: bus, decay: { config.reputationDecay })
        self.dqnAgent = DQNAgent(topology: [8, 32, 16, 3])
        self.scheduler = AbbeyScheduler(
            modelContainer: modelContainer,
            eventBus: bus,
            metrics: metrics,
            cooldownSeconds: { config.replyCooldownSeconds },
            consolidationIntervalMinutes: { config.memoryConsolidationIntervalMinutes }
        )
        self.confirmationGate = ConfirmationGate(eventBus: bus, requireConfirmation: { config.confirmationRequiredForDestructiveActions })
        self.personaRouter = ABIRouter(eventBus: bus)
        self.inferenceRouter = InferenceRouter(
            eventBus: bus,
            metrics: metrics,
            currentMode: { config.inferenceMode },
            remoteEndpoint: { config.remoteEndpoint }
        )

        if storeDegraded {
            metrics.markStoreDegraded()
        }

        startEventListener()
        Task { [socialBrain, scheduler] in
            await socialBrain.warmCache()
            await scheduler.start()
        }

        if config.operatingMode == .liveDiscord, config.autoConnectOnLaunch, !config.discordBotToken.isEmpty {
            Task { await self.connectDiscord() }
        }
    }

    private func startEventListener() {
        let bus = eventBus
        eventListenerTask = Task { [weak self] in
            let stream = await bus.subscribe()
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: AbbeyEvent) async {
        lastEvent = event
        switch event {
        case .messageIngested:
            metrics.recordMessageIngested()
        case .reputationChanged:
            metrics.recordReputationEvent()
        case .destructiveActionConfirmed:
            metrics.recordDestructiveAction(confirmed: true)
        case .destructiveActionCancelled:
            metrics.recordDestructiveAction(confirmed: false)
        case .inferenceProviderFailed(_, let message):
            metrics.recordInferenceFailureMessage(message)
        case .channelContextConsolidated:
            break
        default:
            break
        }
    }

    /// Ingests one message end-to-end: persists it, upserts channel/user memory,
    /// scores sentiment, records a DQN experience (projected to 8 lanes), and nudges
    /// SocialBrain's reputation for the author.
    func ingestMessage(
        content: String,
        channelId: String,
        guildId: String,
        authorId: String,
        discordMessageId: String? = nil
    ) async {
        let started = ContinuousClock.now
        let context = ModelContext(modelContainer)
        let message = GuildMessage(
            discordMessageId: discordMessageId ?? UUID().uuidString,
            channelId: channelId,
            guildId: guildId,
            authorId: authorId,
            content: content
        )
        context.insert(message)
        if discordMessageId != nil {
            liveIngestCount += 1
        }
        upsertChannelContext(in: context, channelId: channelId, guildId: guildId)
        let intent = IntentClassifier.classify(content)
        if intent == .memoryStore {
            appendMemoryFact(in: context, authorId: authorId, guildId: guildId, content: content)
        }
        if intent == .personaSwitch {
            let name = content.lowercased().contains("aviva") ? "Aviva"
                : content.lowercased().contains("abi") ? "Abi" : "Abbey"
            await personaRouter.setPersona(named: name)
        }
        try? context.save()

        await eventBus.publish(.messageIngested(channelId: channelId, guildId: guildId, authorId: authorId))

        let reputationBefore = await socialBrain.reputation(userId: authorId, guildId: guildId)
        let authorInteractionCount = (try? context.fetch(
            FetchDescriptor<UserMemory>(predicate: #Predicate { $0.discordUserId == authorId && $0.guildId == guildId })
        ).first?.interactionCount) ?? 0
        let channelActivity = (try? context.fetch(
            FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.channelId == channelId && $0.guildId == guildId })
        ).first?.messageCount) ?? 0

        let fullState = SentimentAnalyzer.analyze(
            text: content,
            authorReputation: reputationBefore,
            recentReactionCount: 0,
            mentionsSomeone: content.contains("@"),
            isReply: false,
            timestamp: .now,
            channelMessageCountInWindow: channelActivity,
            authorInteractionCount: authorInteractionCount,
            isDirectMessage: false
        )
        let state = SentimentAnalyzer.projectToNetworkInput(fullState)
        let action = await dqnAgent.selectAction(state: state)
        lastDQNAction = action
        await dqnAgent.remember(Experience(state: state, action: action, reward: Float(intent.quality), nextState: state, done: true))
        await dqnAgent.learn()
        await socialBrain.recordInteraction(userId: authorId, guildId: guildId, quality: intent.quality)

        let elapsed = started.duration(to: .now)
        let latencyMs = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        logInteraction(
            commandName: "ingestMessage",
            userId: authorId,
            guildId: guildId,
            succeeded: true,
            latencyMs: latencyMs
        )
    }

    /// Builds a `PersonaContext` from the local SwiftData store for the given author/channel.
    func personaContext(authorId: String, guildId: String, channelId: String) async -> PersonaContext {
        let context = ModelContext(modelContainer)
        let channelKey = "\(guildId):\(channelId)"
        let userKey = "\(guildId):\(authorId)"
        let summary = (try? context.fetch(
            FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.compositeKey == channelKey })
        ).first?.summary) ?? ""
        let facts = (try? context.fetch(
            FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == userKey })
        ).first?.facts) ?? []
        let reputation = await socialBrain.reputation(userId: authorId, guildId: guildId)
        return PersonaContext(channelSummary: summary, userFacts: facts, reputation: reputation)
    }

    func logInteraction(commandName: String, userId: String, guildId: String, succeeded: Bool, latencyMs: Double) {
        let context = ModelContext(modelContainer)
        context.insert(InteractionLog(
            commandName: commandName,
            userId: userId,
            guildId: guildId,
            succeeded: succeeded,
            latencyMs: latencyMs
        ))
        try? context.save()
    }

    /// Routes a destructive moderation action through `ConfirmationGate` before doing
    /// anything. `perform` only runs if the gate resolves `true`.
    func performDestructiveAction(
        _ kind: DestructiveAction,
        targetUserId: String,
        guildId: String,
        reason: String,
        perform: @Sendable () async -> Void
    ) async {
        let approved = await confirmationGate.request(kind: kind, targetUserId: targetUserId, guildId: guildId, reason: reason)
        guard approved else { return }
        await perform()
    }

    private func upsertChannelContext(in context: ModelContext, channelId: String, guildId: String) {
        let key = "\(guildId):\(channelId)"
        let descriptor = FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.compositeKey == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.messageCount += 1
            existing.updatedAt = .now
        } else {
            context.insert(ChannelContext(channelId: channelId, guildId: guildId, messageCount: 1))
        }
    }

    private func appendMemoryFact(in context: ModelContext, authorId: String, guildId: String, content: String) {
        let key = "\(guildId):\(authorId)"
        let fact = content
            .replacingOccurrences(of: #"(?i)^(remember|note that)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return }
        let descriptor = FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })
        if let existing = try? context.fetch(descriptor).first {
            if !existing.facts.contains(fact) {
                existing.facts.append(fact)
                existing.updatedAt = .now
            }
        } else {
            context.insert(UserMemory(discordUserId: authorId, guildId: guildId, facts: [fact]))
        }
    }

    // MARK: - Discord

    func connectDiscord() async {
        let token = config.discordBotToken
        discordState = .connecting
        discordLastError = nil

        let ingress = makeMessageIngress()
        let interactions = makeInteractionRouter()
        let bridge = discordBridge

        let hooks = DiscordEventHooks(
            onReady: { [weak self] userId in
                await MainActor.run {
                    self?.discordBotUserId = userId
                    self?.discordState = .connected
                }
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

        await bridge.connect(token: token, hooks: hooks)
        await refreshDiscordStatus()
    }

    func disconnectDiscord() async {
        await discordBridge.disconnect()
        await refreshDiscordStatus()
    }

    func refreshDiscordStatus() async {
        discordState = await discordBridge.state
        discordLastError = await discordBridge.lastError
        discordBotUserId = await discordBridge.botUserId
    }

    func registerSlashCommands() async throws {
        guard let client = await discordBridge.client else {
            throw InferenceError.remoteEndpointNotConfigured
        }
        let guild = config.discordDevGuildId
        try await CommandRegistry.register(client: client, guildId: guild.isEmpty ? nil : guild)
    }

    func performLiveModeration(
        _ kind: DestructiveAction,
        targetUserId: String,
        guildId: String,
        reason: String,
        channelId: String? = nil,
        messageIds: [String] = []
    ) async {
        let approved = await confirmationGate.request(
            kind: kind,
            targetUserId: targetUserId,
            guildId: guildId,
            reason: reason
        )
        guard approved else { return }

        guard let client = await discordBridge.client else {
            await socialBrain.penalize(userId: targetUserId, guildId: guildId, reason: "\(kind.rawValue): \(reason)")
            return
        }
        do {
            switch kind {
            case .kick:
                try await moderationClient.kick(client: client, guildId: guildId, userId: targetUserId, reason: reason)
            case .ban:
                try await moderationClient.ban(client: client, guildId: guildId, userId: targetUserId, reason: reason)
            case .purge:
                if let channelId {
                    try await moderationClient.purge(client: client, channelId: channelId, messageIds: messageIds)
                }
            }
            await socialBrain.penalize(userId: targetUserId, guildId: guildId, reason: "\(kind.rawValue): \(reason)")
        } catch {
            discordLastError = String(describing: error)
        }
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
                guard let self else { return "Engine unavailable." }
                let persona = await self.personaRouter.currentPersona()
                let context = await self.personaContext(authorId: userId, guildId: guildId, channelId: channelId)
                return await persona.respond(to: question, context: context, inference: self.inferenceRouter).text
            },
            rep: { [weak self] userId, guildId in
                guard let self else { return "Engine unavailable." }
                let value = await self.socialBrain.reputation(userId: userId, guildId: guildId)
                return "Reputation for \(userId): \(String(format: "%.3f", value))"
            },
            remember: { [weak self] userId, guildId, fact in
                guard let self else { return "Engine unavailable." }
                await self.ingestMessage(content: "remember \(fact)", channelId: "slash", guildId: guildId, authorId: userId)
                return "Remembered for \(userId)."
            },
            forget: { [weak self] userId, guildId, index in
                guard let self else { return "Engine unavailable." }
                let context = ModelContext(self.modelContainer)
                let key = "\(guildId):\(userId)"
                guard let memory = try? context.fetch(FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })).first else {
                    return "No memory for that user."
                }
                let idx = index - 1
                guard memory.facts.indices.contains(idx) else { return "Invalid fact index." }
                memory.facts.remove(at: idx)
                try? context.save()
                return "Forgot fact #\(index)."
            },
            context: { [weak self] channelId, guildId in
                guard let self else { return "Engine unavailable." }
                let context = ModelContext(self.modelContainer)
                let key = "\(guildId):\(channelId)"
                let summary = (try? context.fetch(FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.compositeKey == key })).first?.summary) ?? ""
                return summary.isEmpty ? "No channel summary yet." : summary
            },
            persona: { [weak self] name in
                guard let self else { return "Engine unavailable." }
                let mapped = name.lowercased().hasPrefix("av") ? "Aviva" : name.lowercased().hasPrefix("abi") ? "Abi" : "Abbey"
                await self.personaRouter.setPersona(named: mapped)
                return "Switched to \(mapped)."
            }
        )
    }
}
