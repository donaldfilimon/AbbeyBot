import Foundation
import DiscordBM
import Logging

public enum DiscordConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case failed

    /// Title-case label for dashboards and forms (not the wire `rawValue`).
    public var displayName: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        }
    }
}

/// Pure generation-scoped lifecycle used by `DiscordBridge` and deterministic
/// tests. DiscordBM's `connect()` returns after spawning its WebSocket task, so
/// only a current-generation READY is authoritative.
struct DiscordGatewayLifecycle: Sendable {
    struct Generation: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    static let streamEndedError = "Discord Gateway event stream ended unexpectedly."
    static let streamFailedError = "Discord Gateway event stream failed."

    private(set) var state: DiscordConnectionState = .disconnected
    private(set) var lastError: String?
    private(set) var generation = Generation(value: 0)

    @discardableResult
    mutating func beginConnecting() -> Generation {
        advanceGeneration()
        state = .connecting
        lastError = nil
        return generation
    }

    @discardableResult
    mutating func receiveReady(generation candidate: Generation) -> Bool {
        guard candidate == generation, state == .connecting else { return false }
        state = .connected
        lastError = nil
        return true
    }

    @discardableResult
    mutating func eventStreamEnded(generation candidate: Generation) -> Bool {
        fail(generation: candidate, message: Self.streamEndedError)
    }

    @discardableResult
    mutating func eventStreamFailed(generation candidate: Generation) -> Bool {
        fail(generation: candidate, message: Self.streamFailedError)
    }

    mutating func disconnect() {
        // Invalidate callbacks before any asynchronous teardown begins.
        advanceGeneration()
        state = .disconnected
        lastError = nil
    }

    mutating func failCurrentConfiguration() {
        state = .failed
        lastError = "DISCORD_BOT_TOKEN is empty"
    }

    func isCurrent(_ candidate: Generation) -> Bool {
        candidate == generation
    }

    private mutating func fail(generation candidate: Generation, message: String) -> Bool {
        guard candidate == generation, state != .disconnected else { return false }
        state = .failed
        lastError = message
        return true
    }

    private mutating func advanceGeneration() {
        generation = Generation(value: generation.value &+ 1)
    }
}

/// Owns the DiscordBM gateway manager and exposes connect/disconnect for desktop + server.
public actor DiscordBridge {
    public var state: DiscordConnectionState { lifecycle.state }
    public var lastError: String? { lifecycle.lastError }
    public private(set) var botUserId: String?
    /// Current voice-channel presence (gateway update only; no Opus/UDP audio).
    public private(set) var voiceChannelId: String?
    public private(set) var voiceGuildId: String?

    private var gateway: BotGatewayManager?
    private var voiceGatewayCredentials: VoiceGatewayHandshake.Credentials?
    private var voiceGatewayHandshake = VoiceGatewayHandshake()
    private var eventTask: Task<Void, Never>?
    private var lifecycle = DiscordGatewayLifecycle()
    private let logger = Logger(label: "AbbeyBot.DiscordBridge")

    public init() {}

    public var client: (any DiscordClient)? {
        gateway?.client
    }

    /// True when a live BotGatewayManager is held (false under dry-run).
    public var hasGateway: Bool {
        gateway != nil
    }

    public func connect(
        token: String,
        hooks: DiscordEventHooks,
        presenceActivityName: String = "AbbeyBot",
        dryRun: Bool = AppConfig.shared.dryRun
    ) async {
        await disconnect()
        if dryRun {
            let generation = lifecycle.beginConnecting()
            _ = lifecycle.receiveReady(generation: generation)
            botUserId = "dry-run"
            logger.info("dry-run: would connect (presenceActivity=\(presenceActivityName)); gateway skipped")
            await hooks.onReady("dry-run")
            return
        }
        guard !token.isEmpty else {
            lifecycle.failCurrentConfiguration()
            return
        }
        let generation = lifecycle.beginConnecting()

        let bot = await BotGatewayManager(
            token: token,
            presence: .init(
                activities: [.init(name: presenceActivityName, type: .listening)],
                status: .online,
                afk: false
            ),
            intents: [
                .guildMessages,
                .messageContent,
                .guildMembers,
                .directMessages,
                .guildMessageReactions,
                .guildVoiceStates
            ]
        )
        self.gateway = bot

        eventTask = Task { [weak self] in
            for await event in await bot.events {
                guard !Task.isCancelled, let self else { return }
                await self.handleGatewayEvent(event, hooks: hooks, generation: generation)
            }
            guard !Task.isCancelled else { return }
            await self?.noteEventStreamEnded(generation: generation)
        }

        await bot.connect()
    }

    public func disconnect() async {
        lifecycle.disconnect()
        if let guildId = voiceGuildId {
            _ = await leaveVoice(guildId: guildId)
        }
        eventTask?.cancel()
        eventTask = nil
        await gateway?.disconnect()
        // BotGatewayManager has no explicit disconnect API in all versions — drop reference.
        gateway = nil
        botUserId = nil
        voiceChannelId = nil
        voiceGuildId = nil
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.reset()
    }

    /// Appear in a voice channel via gateway `Voice State Update` (self-mute + self-deaf).
    /// DiscordBM has no Opus/UDP — this is presence only, not audio.
    @discardableResult
    public func joinVoice(guildId: String, channelId: String) async -> VoiceUpdateResult {
        guard let gateway else { return .gatewayUnavailable }
        let trimmedGuild = guildId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChannel = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuild.isEmpty, !trimmedChannel.isEmpty else { return .invalidIdentifiers }
        let handshakeResult = beginVoiceGatewayHandshake(guildId: trimmedGuild, channelId: trimmedChannel)
        guard handshakeResult == .requested else { return handshakeResult }
        await gateway.updateVoiceState(
            payload: VoiceStateUpdate(
                guildId: GuildSnowflake(trimmedGuild),
                channelId: ChannelSnowflake(trimmedChannel),
                selfMute: true,
                selfDeaf: true
            )
        )
        voiceGuildId = trimmedGuild
        voiceChannelId = trimmedChannel
        return .requested
    }

    /// Leave voice by sending `channel_id: null` for the guild (defaults to tracked guild).
    @discardableResult
    public func leaveVoice(guildId: String? = nil) async -> VoiceUpdateResult {
        guard let gateway else { return .gatewayUnavailable }
        let trimmed = (guildId ?? voiceGuildId)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .invalidIdentifiers }
        _ = voiceGatewayHandshake.cancel(guildID: trimmed)
        if voiceGatewayCredentials?.guildID == trimmed {
            voiceGatewayCredentials = nil
        }
        await gateway.updateVoiceState(
            payload: VoiceStateUpdate(
                guildId: GuildSnowflake(trimmed),
                channelId: nil,
                selfMute: true,
                selfDeaf: true
            )
        )
        // Only clear tracked presence when leaving the guild we are tracking.
        if voiceGuildId == trimmed {
            voiceGuildId = nil
            voiceChannelId = nil
        }
        return .requested
    }

    /// READY events must enter through `handleGatewayEvent`, which carries the
    /// connection generation. An unscoped callback cannot safely mutate state.
    func noteReady(userId _: String) {
        logger.warning("Ignoring unscoped Discord READY event")
    }

    /// Like READY, a failure without its originating generation is unsafe: a
    /// stale callback must not fail a replacement connection.
    func noteFailure(_: String) {
        logger.warning("Ignoring unscoped Discord Gateway failure")
    }
}

/// Callbacks from gateway handlers into the app engine (Sendable closures).
extension DiscordBridge {
    private func handleGatewayEvent(
        _ event: Gateway.Event,
        hooks: DiscordEventHooks,
        generation: DiscordGatewayLifecycle.Generation
    ) async {
        guard lifecycle.isCurrent(generation), state == .connecting || state == .connected else { return }

        if case .ready(let payload)? = event.data {
            guard lifecycle.receiveReady(generation: generation) else { return }
            let userId = payload.user.id.rawValue
            botUserId = userId
            await hooks.onReady(userId)
            return
        }

        await AbbeyGatewayHandler(event: event, hooks: hooks, bridge: self).handleAsync()
    }

    private func noteEventStreamEnded(generation: DiscordGatewayLifecycle.Generation) {
        guard lifecycle.eventStreamEnded(generation: generation) else { return }
        botUserId = nil
        voiceChannelId = nil
        voiceGuildId = nil
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.reset()
        gateway = nil
        eventTask = nil
        logger.error("Discord bridge failure: \(DiscordGatewayLifecycle.streamEndedError)")
    }

    private func noteEventStreamFailed(generation: DiscordGatewayLifecycle.Generation) {
        guard lifecycle.eventStreamFailed(generation: generation) else { return }
        botUserId = nil
        voiceChannelId = nil
        voiceGuildId = nil
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.reset()
        gateway = nil
        eventTask = nil
        logger.error("Discord bridge failure: \(DiscordGatewayLifecycle.streamFailedError)")
    }

    /// Begins correlation before Gateway opcode 4 is sent.
    private func beginVoiceGatewayHandshake(guildId: String, channelId: String) -> VoiceUpdateResult {
        guard let botUserId else { return .gatewayUnavailable }
        guard voiceGatewayHandshake.begin(guildID: guildId, channelID: channelId, userID: botUserId) != nil else {
            return .requestInProgress
        }
        voiceGatewayCredentials = nil
        return .requested
    }

    /// Transfers ephemeral credentials to the internal media controller once.
    /// Keeping this package-internal prevents UI/server callers from retaining
    /// or displaying the Discord voice capability.
    func consumeVoiceGatewayCredentials() -> VoiceGatewayHandshake.Credentials? {
        defer { voiceGatewayCredentials = nil }
        return voiceGatewayCredentials
    }

    /// Receives the bot's main-Gateway voice-state dispatch. Public voice
    /// presence is updated only after Discord confirms the self state.
    public func handleVoiceStateUpdate(_ payload: VoiceState) {
        guard payload.user_id.rawValue == botUserId else { return }
        let guildId = payload.guild_id.rawValue
        let outcome = voiceGatewayHandshake.receive(
            .init(
                guildID: guildId,
                channelID: payload.channel_id?.rawValue,
                userID: payload.user_id.rawValue,
                sessionID: payload.session_id
            )
        )

        switch outcome {
        case .waiting, .ready:
            voiceChannelId = payload.channel_id?.rawValue
            if case .ready(let credentials) = outcome {
                voiceGatewayCredentials = credentials
            }
        case .cancelled:
            if voiceGatewayCredentials?.guildID == guildId {
                voiceGatewayCredentials = nil
            }
            if voiceGuildId == guildId {
                voiceGuildId = nil
                voiceChannelId = nil
            }
        case .ignored:
            if payload.channel_id == nil, voiceGuildId == guildId {
                voiceGatewayCredentials = nil
                voiceGuildId = nil
                voiceChannelId = nil
            }
        case .rejected:
            break
        }
    }

    /// Receives Discord's ephemeral Voice Gateway endpoint and token. The token
    /// remains actor-local until the future media transport consumes it.
    public func handleVoiceServerUpdate(_ payload: Gateway.VoiceServerUpdate) {
        let outcome = voiceGatewayHandshake.receive(
            .init(
                guildID: payload.guild_id.rawValue,
                endpoint: payload.endpoint,
                token: payload.token
            )
        )
        if case .ready(let credentials) = outcome {
            voiceGatewayCredentials = credentials
        } else if case .rejected(_, .emptyEndpoint) = outcome,
                  voiceGatewayCredentials?.guildID == payload.guild_id.rawValue
        {
            voiceGatewayCredentials = nil
        }
    }
}

public struct DiscordEventHooks: Sendable {
    public var onReady: @Sendable (_ userId: String) async -> Void
    public var onMessageCreate: @Sendable (_ message: Gateway.MessageCreate) async -> Void
    public var onInteractionCreate: @Sendable (_ interaction: Interaction) async -> Void

    public init(
        onReady: @escaping @Sendable (_ userId: String) async -> Void = { _ in },
        onMessageCreate: @escaping @Sendable (_ message: Gateway.MessageCreate) async -> Void = { _ in },
        onInteractionCreate: @escaping @Sendable (_ interaction: Interaction) async -> Void = { _ in }
    ) {
        self.onReady = onReady
        self.onMessageCreate = onMessageCreate
        self.onInteractionCreate = onInteractionCreate
    }
}
