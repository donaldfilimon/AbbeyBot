import Foundation
import SwiftData
import Observation
import AbbeyCore

/// SwiftUI façade over SwiftData + AbbeyCore actors.
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

    private(set) var lastEvent: AbbeyEvent?
    private(set) var lastDQNAction: Int?
    private(set) var discordState: DiscordConnectionState = .disconnected
    private(set) var discordLastError: String?
    private(set) var discordBotUserId: String?
    private(set) var discordVoiceChannelId: String?
    private(set) var discordVoiceGuildId: String?
    private(set) var liveIngestCount: Int = 0

    let discordBridge = DiscordBridge()
    let twitchBridge = TwitchBridge()
    let moderationClient = ModerationClient()
    private var eventListenerTask: Task<Void, Never>?

    init(modelContainer: ModelContainer, storeDegraded: Bool = false) {
        self.modelContainer = modelContainer

        let bus = EventBus()
        self.eventBus = bus

        let config = AppConfig.shared
        do {
            try config.validateForStartup()
        } catch {
            print("[config] validateForStartup: \(OperatorFacingError.message(error))")
        }
        self.socialBrain = SocialBrain(modelContainer: modelContainer, eventBus: bus, decay: { config.reputationDecay })
        let checkpointURL = try? DQNCheckpointStore.defaultURL()
        let journalURL = try? ExperienceJournalStore.defaultURL()
        self.dqnAgent = DQNAgent(
            topology: [8, 32, 16, 3],
            checkpointURL: checkpointURL,
            experienceJournalURL: journalURL
        )
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
        Task { [self, socialBrain, scheduler, dqnAgent, twitchBridge] in
            do {
                try await dqnAgent.loadCheckpointIfPresent()
            } catch {
                print(
                    "[dqn] checkpoint load failed: \(OperatorFacingError.message(error)) — using fresh weights"
                )
            }
            do {
                try await dqnAgent.loadExperienceJournalIfPresent()
            } catch {
                print(
                    "[dqn] experience journal load failed: \(OperatorFacingError.message(error)) — buffer starts empty"
                )
            }
            await socialBrain.warmCache()
            await scheduler.start()
            let token = config.twitchOAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                let hooks = TwitchEventHooks { [weak self] msg in
                    guard let self else { return }
                    let botNick = (await self.twitchBridge.loginNick ?? "").lowercased()
                    if !botNick.isEmpty, msg.login == botNick { return }
                    await self.ingestMessage(
                        content: msg.text,
                        channelId: msg.channel,
                        guildId: "twitch",
                        authorId: msg.login,
                        discordMessageId: "twitch-\(UUID().uuidString)"
                    )
                    if await self.scheduler.isCoolingDown(userId: msg.login, guildId: "twitch") {
                        return
                    }
                    let intent = IntentClassifier.classify(msg.text)
                    let persona = await self.personaRouter.route(intent: intent)
                    let context = await self.personaContext(
                        authorId: msg.login,
                        guildId: "twitch",
                        channelId: msg.channel
                    )
                    let response = await persona.respond(
                        to: msg.text,
                        context: context,
                        inference: self.inferenceRouter
                    )
                    let reply = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !reply.isEmpty else { return }
                    await self.twitchBridge.sendPrivmsg(channel: msg.channel, text: reply)
                    await self.scheduler.markReplied(userId: msg.login, guildId: "twitch")
                }
                await twitchBridge.connect(
                    oauthToken: token,
                    login: config.twitchBotLogin,
                    channel: config.twitchChannel,
                    dryRun: config.dryRun,
                    hooks: hooks
                )
            }
        }

        if !config.syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Non-blocking pull MVP — failures land in SyncStatus only.
            Task { await self.pullFromServer() }
        }

        if config.operatingMode == .liveDiscord, config.autoConnectOnLaunch,
           config.dryRun || !config.discordBotToken.isEmpty {
            Task { await self.connectDiscord() }
        }
    }

    /// Best-effort pull from AbbeyServer list endpoints into SwiftData.
    /// Failures never throw to callers; they are recorded on `SyncStatus`.
    func pullFromServer() async {
        let url = config.syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        guard SyncStatus.shared.beginPull() else { return }

        // A pull attempt means we believe the server may be reachable again — resend
        // anything a prior network blip left in the durable outbox first, so the pull
        // below can observe their server-side effects (e.g. reputation re-derived from
        // a flushed ingest).
        _ = await AbbeyServerClient.shared.flushPendingPushes()

        // Ask the server only for rows touched since our last successful pull. The cursor is
        // persisted, so this stays incremental across relaunches too, not just within a session.
        let cursorStore = SyncCursorStore()
        let cursor = cursorStore.lastPullSuccessAt

        // Stamp the *start* of the pull, not its completion: a row the server writes while this
        // pull is in flight may or may not appear in the response, so advancing the cursor to the
        // end time could skip it permanently. Starting-time means such a row is simply refetched
        // next pull — duplicate work, never lost data.
        let attemptStartedAt = Date()

        do {
            let counts = try await SyncPull.run(into: modelContainer, since: cursor)
            SyncStatus.shared.recordPullSuccess(
                users: counts.usersUpserted,
                channels: counts.channelsUpserted,
                messages: counts.messagesInserted,
                reputation: counts.reputationInserted,
                interactions: counts.interactionsInserted,
                equity: counts.equityUpserted
            )
            cursorStore.record(attemptStartedAt)
            await socialBrain.warmCache()
        } catch {
            print("[sync] pull failed: \(error)")
            SyncStatus.shared.recordPullFailure(message: OperatorFacingError.message(error))
        }

        await reportSyncStatusToServer()
    }

    /// Best-effort report of this session's sync outcome for the operator dashboard's
    /// Sync tab. Never throws; failures just don't update the dashboard's view of us.
    private func reportSyncStatusToServer() async {
        let status = SyncStatus.shared
        await AbbeyServerClient.shared.reportSyncStatus(
            lastPullAt: status.lastPullSuccessAt,
            lastPullError: status.lastPullError,
            lastPushAt: status.lastSuccessAt,
            lastPushError: status.lastError,
            pendingPushCount: AbbeyServerClient.shared.pendingPushCount()
        )
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
        default:
            break
        }
    }

    /// Persist message, run shared ingest scoring, update reputation.
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
            await personaRouter.setPersona(named: PersonaName.resolve(content))
        }
        try? context.save()

        Task.detached(priority: .utility) {
            await AbbeyServerClient.shared.ingest(
                content: content,
                channelId: channelId,
                guildId: guildId,
                authorId: authorId,
                discordMessageId: discordMessageId
            )
        }

        await eventBus.publish(.messageIngested(channelId: channelId, guildId: guildId, authorId: authorId))

        let reputationBefore = await socialBrain.reputation(userId: authorId, guildId: guildId)
        let authorInteractionCount = (try? context.fetch(
            FetchDescriptor<UserMemory>(predicate: #Predicate { $0.discordUserId == authorId && $0.guildId == guildId })
        ).first?.interactionCount) ?? 0
        let channelActivity = (try? context.fetch(
            FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.channelId == channelId && $0.guildId == guildId })
        ).first?.messageCount) ?? 0

        let scored = await IngestScorer.scoreAndLearn(
            content: content,
            guildId: guildId,
            reputationBefore: reputationBefore,
            authorInteractionCount: authorInteractionCount,
            channelMessageCount: channelActivity,
            dqnAgent: dqnAgent,
            intent: intent
        )
        lastDQNAction = scored.action
        await socialBrain.recordInteraction(userId: authorId, guildId: guildId, quality: scored.quality)

        logInteraction(
            commandName: "ingestMessage",
            userId: authorId,
            guildId: guildId,
            succeeded: true,
            latencyMs: IngestScorer.latencyMilliseconds(since: started)
        )
    }

    func personaContext(authorId: String, guildId: String, channelId: String) async -> PersonaContext {
        let context = ModelContext(modelContainer)
        let channelKey = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
        let userKey = ReputationMath.cacheKey(userId: authorId, guildId: guildId)
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
        let key = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
        let descriptor = FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.compositeKey == key })
        if let existing = try? context.fetch(descriptor).first {
            existing.messageCount += 1
            existing.updatedAt = .now
        } else {
            context.insert(ChannelContext(channelId: channelId, guildId: guildId, messageCount: 1))
        }
    }

    private func appendMemoryFact(in context: ModelContext, authorId: String, guildId: String, content: String) {
        let key = ReputationMath.cacheKey(userId: authorId, guildId: guildId)
        let fact = MemoryFactText.extract(from: content)
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
        Task.detached(priority: .utility) {
            await AbbeyServerClient.shared.remember(guildId: guildId, userId: authorId, fact: fact)
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

        await bridge.connect(
            token: token,
            hooks: hooks,
            presenceActivityName: "AbbeyBot desktop",
            dryRun: config.dryRun
        )
        await refreshDiscordStatus()
    }

    func disconnectDiscord() async {
        await discordBridge.disconnect()
        await refreshDiscordStatus()
    }

    /// Cancel listeners, stop consolidation, disconnect Discord.
    func shutdown() async {
        eventListenerTask?.cancel()
        eventListenerTask = nil
        await scheduler.stop()
        await disconnectDiscord()
    }

    func refreshDiscordStatus() async {
        discordState = await discordBridge.state
        discordLastError = await discordBridge.lastError
        discordBotUserId = await discordBridge.botUserId
        discordVoiceChannelId = await discordBridge.voiceChannelId
        discordVoiceGuildId = await discordBridge.voiceGuildId
    }

    /// Gateway voice presence only (muted/deafened; no Opus/UDP audio).
    @discardableResult
    func joinVoice(guildId: String, channelId: String) async -> String {
        let message = await performVoice(.join(channelId: channelId), guildId: guildId)
        await refreshDiscordStatus()
        return message
    }

    /// Leave tracked (or given) guild voice presence.
    @discardableResult
    func leaveVoice(guildId: String? = nil) async -> String {
        let gid = guildId ?? discordVoiceGuildId ?? ""
        let message = await performVoice(.leave, guildId: gid)
        await refreshDiscordStatus()
        return message
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
            discordLastError = OperatorFacingError.message(error)
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
                await self.ingestMessage(content: "remember \(fact)", channelId: "slash", guildId: guildId, authorId: userId)
                return DiscordCopy.remembered(userId: userId)
            },
            forget: { [weak self] userId, guildId, index in
                guard let self else { return DiscordCopy.engineUnavailable }
                let context = ModelContext(self.modelContainer)
                let key = ReputationMath.cacheKey(userId: userId, guildId: guildId)
                guard let memory = try? context.fetch(FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })).first else {
                    return DiscordCopy.noMemory
                }
                let idx = index - 1
                guard memory.facts.indices.contains(idx) else { return DiscordCopy.invalidFactIndex }
                memory.facts.remove(at: idx)
                try? context.save()
                Task.detached(priority: .utility) {
                    await AbbeyServerClient.shared.forget(guildId: guildId, userId: userId, index: index)
                }
                return DiscordCopy.forgot(index: index)
            },
            context: { [weak self] channelId, guildId in
                guard let self else { return DiscordCopy.engineUnavailable }
                let context = ModelContext(self.modelContainer)
                let key = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
                let summary = (try? context.fetch(FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.compositeKey == key })).first?.summary) ?? ""
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
                let message = await self.performVoice(action, guildId: guildId)
                await self.refreshDiscordStatus()
                return message
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
