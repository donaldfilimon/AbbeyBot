import AbbeyCore
import AbbeyQuasarKit
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

/// The desktop-reported sync outcome as stored in this runtime's database, plus the dialect
/// it came from. The server never pushes or pulls; the CLI can pull (`/sync pull`) but
/// reporting into this row stays a desktop concern.
public struct SyncStatusSnapshotDTO: Content, Sendable {
    public var databaseDialect: String
    public var lastPullAt: Date?
    public var lastPullError: String?
    public var lastPushAt: Date?
    public var lastPushError: String?
    public var pendingPushCount: Int
    public var reportedAt: Date?

    public init(
        databaseDialect: String,
        lastPullAt: Date? = nil,
        lastPullError: String? = nil,
        lastPushAt: Date? = nil,
        lastPushError: String? = nil,
        pendingPushCount: Int = 0,
        reportedAt: Date? = nil
    ) {
        self.databaseDialect = databaseDialect
        self.lastPullAt = lastPullAt
        self.lastPullError = lastPullError
        self.lastPushAt = lastPushAt
        self.lastPushError = lastPushError
        self.pendingPushCount = pendingPushCount
        self.reportedAt = reportedAt
    }
}

public enum BotRuntimeEventProcessingError: Error, LocalizedError, Sendable {
    case ingestFailed

    public var errorDescription: String? {
        switch self {
        case .ingestFailed:
            return "Event persistence failed; the delivery should be retried."
        }
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
    /// Links Discord replies to the DQN sample that chose their strategy (reaction rewards).
    let rewardLedger: DelayedRewardLedger
    let scheduler: FluentScheduler
    let personaRouter: ABIRouter
    public let inferenceRouter: InferenceRouter
    public let knowledgeIndex: KnowledgeIndex
    public let knowledgeInitializationError: String?
    /// Payloads and permission facts are resolved on this service, never supplied by a desktop.
    public func approveDiscordQuasarProposal(id: UUID, digest: String) async throws {
        guard let service = quasarService,
              let proposal = await service.pendingDiscordProposals().first(where: { $0.id == id }),
              proposal.digest == digest else { throw QuasarError.proposalChanged }
        let permission = await discordBridge.currentManagerAuthorization(
            guildID: proposal.facts.guildID, userID: proposal.facts.initiatorID)
        let facts = QuasarAuthorizationFacts.current(guildID: proposal.facts.guildID,
            initiatorID: proposal.facts.initiatorID, discordPermissionAllowed: permission)
        _ = try await service.approveDiscordProposal(id: id, digest: digest, revalidated: facts)
    }

    public let quasarService: QuasarService?
    public let quasarInitializationError: String?
    let discordBridge = DiscordBridge()
    let twitchBridge = TwitchBridge()
    /// Local WDBX segment store (`~/.abbey/wdbx/`).
    let wdbxStore: WDBXStore?
    public private(set) var lastStrategy: StrategyAction = .answer

    public private(set) var discordState: DiscordConnectionState = .disconnected
    private(set) var discordLastError: String?
    private(set) var discordBotUserId: String?
    private(set) var liveIngestCount: Int = 0
    /// Last observed Twitch EventSub stream lifecycle. `nil` until the first
    /// `stream.online` / `stream.offline` notification arrives this process.
    public internal(set) var twitchStreamLive: Bool?
    private var metricsListener: Task<Void, Never>?

    init(app: Application) {
        self.app = app
        let config = AppConfig.shared
        self.config = config
        self.rewardLedger = DelayedRewardLedger(isEnabled: config.delayedRewardsEnabled)
        let metrics = EngineMetrics()
        self.metrics = metrics
        let bus = EventBus()
        self.eventBus = bus
        self.socialBrain = FluentSocialBrain(db: app.db, eventBus: bus, decay: { config.reputationDecay })
        let checkpointURL = try? DQNCheckpointStore.defaultURL()
        let store = try? WDBXStore()
        self.wdbxStore = store
        let experiencePersistence: DQNExperiencePersistence?
        if let wdbxFacade = try? WDBXMemoryFacade.default(store: store) {
            experiencePersistence = .memory(wdbxFacade)
        } else if let journalURL = try? ExperienceJournalStore.defaultURL() {
            experiencePersistence = .journal(ExperienceJournal(url: journalURL))
        } else {
            experiencePersistence = nil
        }
        self.dqnAgent = DQNAgent(
            topology: DQNAgent.defaultTopology,
            checkpointURL: checkpointURL,
            experiencePersistence: experiencePersistence
        )
        self.scheduler = FluentScheduler(
            db: app.db,
            logger: app.logger,
            eventBus: bus,
            metrics: metrics,
            cooldownSeconds: { config.replyCooldownSeconds },
            consolidationIntervalMinutes: { config.memoryConsolidationIntervalMinutes }
        )
        self.personaRouter = ABIRouter(eventBus: bus)
        let inferenceRouter = InferenceRouter(
            eventBus: bus,
            metrics: metrics,
            currentMode: { config.inferenceMode },
            remoteEndpoint: { config.remoteEndpoint },
            remoteModel: { config.remoteModel },
            remoteAPIToken: { config.remoteAPIToken }
        )
        self.inferenceRouter = inferenceRouter
        do {
            self.knowledgeIndex = KnowledgeIndex(documents: try KnowledgeSnapshotLoader.loadVerified())
            self.knowledgeInitializationError = nil
        } catch {
            self.knowledgeIndex = KnowledgeIndex()
            self.knowledgeInitializationError = OperatorFacingError.message(error)
        }
        do {
            self.quasarService = try QuasarService(planner: .abbey(router: inferenceRouter))
            self.quasarInitializationError = nil
        } catch {
            self.quasarService = nil
            self.quasarInitializationError = OperatorFacingError.message(error)
        }
    }

    public func start() async {
        do {
            try await dqnAgent.loadCheckpointIfPresent()
        } catch {
            app.logger.warning(
                "DQN checkpoint load failed: \(OperatorFacingError.message(error)) — using fresh weights"
            )
        }
        do {
            try await dqnAgent.loadExperienceJournalIfPresent()
        } catch {
            app.logger.warning(
                "DQN experience journal load failed: \(OperatorFacingError.message(error)) — buffer starts empty"
            )
        }
        await socialBrain.warmCache()
        await scheduler.start()
        let twitchToken = config.twitchOAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !config.dryRun, !twitchToken.isEmpty {
            let hooks = TwitchEventHooks { [weak self] msg in
                guard let self else { return }
                await self.handleTwitchChat(login: msg.login, channel: msg.channel, text: msg.text)
            }
            await twitchBridge.connect(
                oauthToken: twitchToken,
                login: config.twitchBotLogin,
                channel: config.twitchChannel,
                dryRun: config.dryRun,
                hooks: hooks
            )
        }
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
        await twitchBridge.disconnect()
        await discordBridge.disconnect()
        await quasarService?.shutdown()
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
        let rewardLedger = rewardLedger
        let dqnAgent = dqnAgent

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
            },
            onMessageReactionAdd: { reaction in
                await ReactionRewardIngress.apply(
                    reaction,
                    botUserId: await bridge.botUserId,
                    ledger: rewardLedger,
                    dqnAgent: dqnAgent
                )
            },
            onMessageDelete: { deleted in
                await ReplyDeletionIngress.apply(deleted, ledger: rewardLedger, dqnAgent: dqnAgent)
            },
            onMessageDeleteBulk: { deleted in
                await ReplyDeletionIngress.apply(deleted, ledger: rewardLedger, dqnAgent: dqnAgent)
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

    /// Ingest with a typed, message-scoped outcome.  The selected strategy travels with the
    /// inserted message so actor reentrancy cannot apply another message's strategy later.
    @discardableResult
    public func ingestMessageOutcome(
        content: String,
        channelId: String,
        guildId: String,
        authorId: String,
        discordMessageId: String
    ) async -> MessageIngestOutcome {
        let started = ContinuousClock.now
        let intent = IntentClassifier.classify(content)
        let persisted: (authorInteractionCount: Int, channelActivity: Int)?
        do {
            persisted = try await app.db.transaction { database in
                if try await MessageRepository.exists(discordMessageId: discordMessageId, on: database) {
                    return nil
                }
                try await MessageRepository.insert(
                    discordMessageId: discordMessageId,
                    channelId: channelId,
                    guildId: guildId,
                    authorId: authorId,
                    content: content,
                    on: database
                )
                try await ChannelRepository.bump(channelId: channelId, guildId: guildId, on: database)

                if intent == .memoryStore {
                    let fact = MemoryFactText.extract(from: content)
                    try await MemoryRepository.appendFact(
                        userId: authorId,
                        guildId: guildId,
                        fact: fact,
                        on: database
                    )
                }

                let interactionCount = try await UserMemory.query(on: database)
                    .filter(\.$discordUserId == authorId)
                    .filter(\.$guildId == guildId)
                    .first()?.interactionCount ?? 0
                let channelActivity = try await ChannelRepository.messageCount(
                    channelId: channelId,
                    guildId: guildId,
                    on: database
                )
                return (interactionCount, channelActivity)
            }
        } catch {
            // A concurrent insert can win after the existence check. Only a confirmed
            // durable row is a duplicate; every other storage failure remains retryable.
            if (try? await MessageRepository.exists(discordMessageId: discordMessageId, on: app.db)) == true {
                return .duplicate
            }
            app.logger.error("ingest persistence failed: \(OperatorFacingError.message(error))")
            return .failed
        }

        guard let persisted else {
            app.logger.info(
                "ingest skipped — discordMessageId=\(discordMessageId) already present (duplicate)"
            )
            return .duplicate
        }
        liveIngestCount += 1

        await eventBus.publish(.messageIngested(channelId: channelId, guildId: guildId, authorId: authorId))

        let reputationBefore = await socialBrain.reputation(userId: authorId, guildId: guildId)
        let scored = await IngestScorer.scoreAndLearn(
            content: content,
            guildId: guildId,
            reputationBefore: reputationBefore,
            authorInteractionCount: persisted.authorInteractionCount,
            channelMessageCount: persisted.channelActivity,
            dqnAgent: dqnAgent,
            intent: intent,
            wdbx: wdbxStore,
            authorId: authorId,
            channelId: channelId
        )
        lastStrategy = scored.strategy
        await rewardLedger.stage(
            sourceMessageId: discordMessageId,
            authorId: authorId,
            guildId: guildId,
            state: scored.state,
            action: scored.action
        )
        await socialBrain.recordInteraction(userId: authorId, guildId: guildId, quality: scored.quality)

        do {
            try await InteractionRepository.log(
                commandName: "ingestMessage",
                userId: authorId,
                guildId: guildId,
                succeeded: true,
                latencyMs: IngestScorer.latencyMilliseconds(since: started),
                on: app.db
            )
        } catch {
            // The message transaction already committed. Audit telemetry is best-effort and
            // must not turn a successful ingest into a misleading retryable failure.
            app.logger.warning("ingest audit failed: \(OperatorFacingError.message(error))")
        }
        return .inserted(strategy: scored.strategy)
    }

    /// Compatibility surface used by HTTP and existing repository tests.  New transport
    /// paths should prefer `ingestMessageOutcome` so duplicate and failure stay distinct.
    @discardableResult
    public func ingestMessage(
        content: String,
        channelId: String,
        guildId: String,
        authorId: String,
        discordMessageId: String
    ) async -> Bool {
        await ingestMessageOutcome(
            content: content,
            channelId: channelId,
            guildId: guildId,
            authorId: authorId,
            discordMessageId: discordMessageId
        ).wasInserted
    }

    /// Ingest a normalized multi-platform social envelope (YouTube / X / Bluesky / Mastodon).
    @discardableResult
    public func handleSocialEnvelope(_ envelope: SocialIngestEnvelope) async -> MessageIngestOutcome {
        await ingestMessageOutcome(
            content: envelope.text,
            channelId: envelope.ingestChannelId,
            guildId: envelope.ingestGuildId,
            authorId: envelope.ingestAuthorId,
            discordMessageId: "\(envelope.platform.rawValue)-\(envelope.messageId)"
        )
    }

    /// A memory read that *failed* is not the same as a user who has no memories, and Abbey
    /// must not answer as a stranger without the operator hearing about it. Every persistence
    /// read that degrades to an empty result funnels through here so it emits the same
    /// `OperatorFacingError` line the ingest path already uses, at `warning` because the reply
    /// still goes out — just with less context than the user actually has stored.
    private func degradingRead<T>(
        _ operation: String,
        fallback: T,
        _ read: () async throws -> T
    ) async -> T {
        do {
            return try await read()
        } catch {
            app.logger.warning("\(operation) failed: \(OperatorFacingError.message(error))")
            return fallback
        }
    }

    func personaContext(authorId: String, guildId: String, channelId: String) async -> PersonaContext {
        let summary = await degradingRead("persona channel-summary read", fallback: "") {
            try await ChannelRepository.summary(channelId: channelId, guildId: guildId, on: app.db)
        }
        let facts = await degradingRead("persona user-facts read", fallback: []) {
            try await MemoryRepository.facts(userId: authorId, guildId: guildId, on: app.db)
        }
        let reputation = await socialBrain.reputation(userId: authorId, guildId: guildId)
        return PersonaContext(
            channelSummary: summary,
            userFacts: facts,
            reputation: reputation,
            knowledgeIndex: knowledgeIndex,
            knowledgeScopes: ["public"],
            evidenceBudget: 4
        )
    }

    private func auditSlashCommand(
        commandName: String,
        userId: String,
        guildId: String,
        succeeded: Bool,
        latencyMs: Double
    ) async {
        do {
            try await InteractionRepository.log(
                commandName: commandName,
                userId: userId,
                guildId: guildId,
                succeeded: succeeded,
                latencyMs: latencyMs,
                on: app.db
            )
        } catch {
            app.logger.warning(
                "slash interaction audit failed: \(OperatorFacingError.message(error))"
            )
        }
    }

    func craftReply(
        content: String,
        channelId: String,
        guildId: String,
        authorId: String,
        strategy: StrategyAction
    ) async -> String? {
        let intent = IntentClassifier.classify(content)
        if strategy == .refuse && (intent == .modRequest || intent == .command) {
            return "I won’t take automated moderation actions from chat. Use a human moderator or `/mod` for advice only."
        }

        let persona = await personaRouter.route(intent: intent, userText: content)
        // Retrieval uses the authoritative memory/channel stores in `personaContext`.
        // WDBX holds scoped strategy vectors only, never a second copy of raw user text.
        let context = await personaContext(authorId: authorId, guildId: guildId, channelId: channelId)
        let directed = strategy.replyDirective(userText: content, retrievedFacts: context.userFacts)
        return await persona.respond(to: directed, context: context, inference: inferenceRouter).text
    }

    /// Persona reply to free text, outside the Discord message/interaction flow — used by
    /// the CLI's conversation loop, mirroring `makeInteractionRouter`'s `ask` closure.
    public func reply(
        to text: String,
        userId: String,
        guildId: String,
        channelId: String,
        strategy: StrategyAction = .answer
    ) async -> String {
        await craftReply(
            content: text,
            channelId: channelId,
            guildId: guildId,
            authorId: userId,
            strategy: strategy
        ) ?? ""
    }

    /// Keyed read of a user's shared state — used by the desktop app's sync client
    /// (and anything else that needs facts/reputation without a channel in hand).
    public func userState(userId: String, guildId: String) async -> UserStateDTO {
        let facts = await degradingRead("user-state facts read", fallback: []) {
            try await MemoryRepository.facts(userId: userId, guildId: guildId, on: app.db)
        }
        let reputation = await socialBrain.reputation(userId: userId, guildId: guildId)
        return UserStateDTO(facts: facts, reputation: reputation)
    }

    /// Keyed read of a channel's shared state (summary only — message count is
    /// available via `/api/channels`).
    public func channelState(channelId: String, guildId: String) async -> ChannelStateDTO {
        let summary = await degradingRead("channel-state summary read", fallback: "") {
            try await ChannelRepository.summary(channelId: channelId, guildId: guildId, on: app.db)
        }
        return ChannelStateDTO(summary: summary)
    }

    /// Direct remember, outside the "remember ..." intent-classification round-trip —
    /// used by the desktop app's sync client and anything else with a fact in hand already.
    @discardableResult
    public func remember(userId: String, guildId: String, fact: String) async throws -> MemoryFactPolicy.Outcome {
        try await MemoryRepository.appendFact(userId: userId, guildId: guildId, fact: fact, on: app.db)
    }

    /// Direct forget by 1-based fact index (same indexing as the `/forget` slash command).
    public func forget(userId: String, guildId: String, index: Int) async throws {
        try await MemoryRepository.forgetFact(userId: userId, guildId: guildId, index: index, on: app.db)
    }

    /// Soft-delete a user-memory row so incremental sync pulls can tombstone it on desktop.
    public func tombstoneUser(userId: String, guildId: String) async throws {
        try await MemoryRepository.softDelete(userId: userId, guildId: guildId, on: app.db)
    }

    /// Soft-delete a channel-context row so incremental sync pulls can tombstone it on desktop.
    public func tombstoneChannel(channelId: String, guildId: String) async throws {
        try await ChannelRepository.softDelete(channelId: channelId, guildId: guildId, on: app.db)
    }

    public func tombstoneMessage(discordMessageId: String) async throws {
        try await MessageRepository.softDelete(discordMessageId: discordMessageId, on: app.db)
    }

    public func tombstoneReputation(id: UUID) async throws {
        try await ReputationRepository.softDelete(id: id, on: app.db)
    }

    public func tombstoneInteraction(id: UUID) async throws {
        try await InteractionRepository.softDelete(id: id, on: app.db)
    }

    public func tombstoneEquity(symbol: String) async throws {
        try await EquityRepository.softDelete(symbol: symbol, on: app.db)
    }

    /// The runtime's default Fluent database — exposed for the CLI's `/sync pull`, which
    /// applies pulled server rows via `ServerSyncApply` without opening a second connection.
    public var database: any Database {
        app.db
    }

    /// The sync-status row visible in *this* runtime's database. When the CLI runs on its own
    /// local SQLite file this is empty — the desktop reports into the server's database, so a
    /// meaningful row only appears when `ABBEY_CLI_USE_SERVER_DATABASE=1` points both at one DB.
    public func syncStatusSnapshot() async -> SyncStatusSnapshotDTO {
        let dialect = app.databaseDialect
        guard let record = try? await SyncStatusRepository.current(on: app.db) else {
            return SyncStatusSnapshotDTO(databaseDialect: dialect)
        }
        return SyncStatusSnapshotDTO(
            databaseDialect: dialect,
            lastPullAt: record.lastPullAt,
            lastPullError: record.lastPullError,
            lastPushAt: record.lastPushAt,
            lastPushError: record.lastPushError,
            pendingPushCount: record.pendingPushCount,
            reportedAt: record.reportedAt
        )
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
                guard let self else { return .failed }
                return await self.ingestMessageOutcome(
                    content: content,
                    channelId: channelId,
                    guildId: guildId,
                    authorId: authorId,
                    discordMessageId: messageId
                )
            },
            craftReply: { [weak self] content, channelId, guildId, authorId, strategy in
                guard let self else { return nil }
                return await self.craftReply(
                    content: content,
                    channelId: channelId,
                    guildId: guildId,
                    authorId: authorId,
                    strategy: strategy
                )
            },
            isCoolingDown: { [weak self] userId, guildId in
                guard let self else { return false }
                return await self.scheduler.isCoolingDown(userId: userId, guildId: guildId)
            },
            markReplied: { [weak self] userId, guildId in
                guard let self else { return }
                await self.scheduler.markReplied(userId: userId, guildId: guildId)
            },
            noteReply: { [rewardLedger] sourceMessageId, replyMessageId in
                await rewardLedger.bind(sourceMessageId: sourceMessageId, replyMessageId: replyMessageId)
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
                    let outcome = try await MemoryRepository.appendFact(
                        userId: userId, guildId: guildId, fact: fact, on: self.app.db
                    )
                    return DiscordCopy.remembered(
                        userId: userId, truncated: outcome.truncated, evicted: outcome.evicted
                    )
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
                let summary = await self.degradingRead(
                    "/context channel-summary read",
                    fallback: ""
                ) {
                    try await ChannelRepository.summary(
                        channelId: channelId,
                        guildId: guildId,
                        on: self.app.db
                    )
                }
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
            },
            help: { DiscordSlashLogic.helpText() },
            status: { [weak self] _, _ in
                guard let self else { return DiscordCopy.engineUnavailable }
                let persona = await self.personaRouter.currentPersona().name
                let snap = await self.metricsSnapshot()
                return DiscordCopy.statusReport(
                    persona: persona,
                    inference: DiscordSlashLogic.displayInferenceMode(AppConfig.shared.inferenceMode),
                    discord: snap.discordState,
                    messages: snap.messagesIngested,
                    inferenceCalls: snap.inferenceCalls,
                    inferenceFailures: snap.inferenceFailures,
                    lastInferenceError: snap.lastInferenceError,
                    industry: AppConfig.shared.industryProfile.rawValue,
                    equityEnabled: AppConfig.shared.equityModuleEnabled,
                    dryRun: AppConfig.shared.dryRun,
                    delayedRewards: self.rewardLedger.isEnabled,
                    replayBufferCount: await self.dqnAgent.bufferCount()
                )
            },
            model: { raw in
                if let raw, !raw.isEmpty {
                    guard let mode = DiscordSlashLogic.resolveInferenceMode(raw) else {
                        return DiscordCopy.modelUnknown
                    }
                    AppConfig.shared.inferenceMode = mode
                    return DiscordCopy.modelSet(DiscordSlashLogic.displayInferenceMode(mode))
                }
                return DiscordCopy.modelCurrent(
                    DiscordSlashLogic.displayInferenceMode(AppConfig.shared.inferenceMode)
                )
            },
            summarize: { [weak self] channelId, guildId, userId in
                guard let self else { return DiscordCopy.engineUnavailable }
                let persona = await self.personaRouter.route(intent: .question)
                let context = await self.personaContext(authorId: userId, guildId: guildId, channelId: channelId)
                let prompt = """
                Summarize this Discord channel memory for an operator. Be concise (≤ 8 bullets). \
                Call out open questions, tone, and any reputation/facts signals.

                Channel summary:
                \(context.channelSummary.isEmpty ? "(empty)" : context.channelSummary)
                """
                return await persona.respond(to: prompt, context: context, inference: self.inferenceRouter).text
            },
            explain: { [weak self] topic, userId, guildId, channelId in
                guard let self else { return DiscordCopy.engineUnavailable }
                let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return DiscordCopy.emptyTopic }
                let persona = await self.personaRouter.route(intent: .question)
                let context = await self.personaContext(authorId: userId, guildId: guildId, channelId: channelId)
                let prompt = "Explain clearly for a skilled engineer: \(trimmed)"
                return await persona.respond(to: prompt, context: context, inference: self.inferenceRouter).text
            },
            facts: { [weak self] userId, guildId in
                guard let self else { return DiscordCopy.engineUnavailable }
                let facts = await self.degradingRead("/facts user-facts read", fallback: []) {
                    try await MemoryRepository.facts(
                        userId: userId,
                        guildId: guildId,
                        on: self.app.db
                    )
                }
                return DiscordSlashLogic.formatFacts(userId: userId, facts: facts)
            },
            ping: {
                let start = ContinuousClock.now
                let ms = IngestScorer.latencyMilliseconds(since: start)
                return DiscordCopy.ping(latencyMs: ms)
            },
            equity: { symbol in
                DiscordSlashLogic.formatEquity(
                    symbol: symbol,
                    enabled: AppConfig.shared.equityModuleEnabled
                )
            },
            modAdvice: { [weak self] situation, userId, guildId, channelId in
                guard let self else { return DiscordCopy.engineUnavailable }
                let trimmed = situation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return DiscordCopy.emptySituation }
                let persona = await self.personaRouter.route(intent: .modRequest)
                let context = await self.personaContext(authorId: userId, guildId: guildId, channelId: channelId)
                let prompt = """
                Moderation advice only — do not claim you executed kicks, bans, or purges. \
                Recommend proportionate steps, what to document, and when to escalate.

                Situation:
                \(trimmed)
                """
                return await persona.respond(to: prompt, context: context, inference: self.inferenceRouter).text
            },
            industry: {
                let profile = AppConfig.shared.industryProfile
                return DiscordCopy.industryProfile(
                    profile.rawValue,
                    suffixEmpty: profile.promptSuffix.isEmpty
                )
            },
            knowledge: { [weak self] query, _, _ in
                guard let self else { return DiscordCopy.engineUnavailable }
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (2...300).contains(trimmed.count) else { return "Knowledge queries must contain 2...300 characters." }
                let hits = await self.knowledgeIndex.search(.init(text: trimmed, callerScope: "public", evidenceBudget: 4))
                guard !hits.isEmpty else { return "No applicable signed-corpus evidence found." }
                return hits.map { hit in
                    "**\(hit.title)** [\(hit.provenance.rawValue)]\n\(hit.excerpt)\n`\(hit.sourceRepository)@\(hit.sourceRevision.prefix(12)):\(hit.sourcePath)`"
                }.joined(separator: "\n\n")
            },
            quasar: { [weak self] request in
                guard let self, let service = self.quasarService else { return self?.quasarInitializationError ?? DiscordCopy.engineUnavailable }
                let facts = QuasarAuthorizationFacts.current(
                    guildID: request.guildID,
                    initiatorID: request.initiatorID,
                    discordPermissionAllowed: request.managerAuthorized
                )
                return await service.handleDiscord(request, facts: facts)
            },
            audit: { [weak self] commandName, userId, guildId, succeeded, latencyMs in
                guard let self else { return }
                await self.auditSlashCommand(
                    commandName: commandName,
                    userId: userId,
                    guildId: guildId,
                    succeeded: succeeded,
                    latencyMs: latencyMs
                )
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
