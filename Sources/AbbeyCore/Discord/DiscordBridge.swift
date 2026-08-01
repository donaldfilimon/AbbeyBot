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

/// Owns the DiscordBM gateway manager and exposes connect/disconnect for desktop + server.
public actor DiscordBridge {
    public private(set) var state: DiscordConnectionState = .disconnected
    public private(set) var lastError: String?
    public private(set) var botUserId: String?
    /// Current voice-channel presence (gateway update only; no Opus/UDP audio).
    public private(set) var voiceChannelId: String?
    public private(set) var voiceGuildId: String?

    private var gateway: BotGatewayManager?
    public private(set) var voiceGatewayCredentials: VoiceGatewayHandshake.Credentials?
    private var voiceGatewayHandshake = VoiceGatewayHandshake()
    private var eventTask: Task<Void, Never>?
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
        if dryRun {
            await disconnect()
            state = .connected
            lastError = nil
            botUserId = "dry-run"
            logger.info("dry-run: would connect (presenceActivity=\(presenceActivityName)); gateway skipped")
            await hooks.onReady("dry-run")
            return
        }
        guard !token.isEmpty else {
            state = .failed
            lastError = "DISCORD_BOT_TOKEN is empty"
            return
        }
        await disconnect()
        state = .connecting
        lastError = nil

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
                guard let self else { return }
                await AbbeyGatewayHandler(event: event, hooks: hooks, bridge: self).handleAsync()
            }
        }

        await bot.connect()
        state = .connected
    }

    public func disconnect() async {
        if let guildId = voiceGuildId {
            _ = await leaveVoice(guildId: guildId)
        }
        eventTask?.cancel()
        eventTask = nil
        await gateway?.disconnect()
        // BotGatewayManager has no explicit disconnect API in all versions — drop reference.
        gateway = nil
        state = .disconnected
        botUserId = nil
        voiceChannelId = nil
        voiceGuildId = nil
    }

    /// Appear in a voice channel via gateway `Voice State Update` (self-mute + self-deaf).
    /// DiscordBM has no Opus/UDP — this is presence only, not audio.
    @discardableResult
    public func joinVoice(guildId: String, channelId: String) async -> VoiceUpdateResult {
        guard let gateway else { return .gatewayUnavailable }
        let trimmedGuild = guildId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChannel = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuild.isEmpty, !trimmedChannel.isEmpty else { return .invalidIdentifiers }
        guard beginVoiceGatewayHandshake(guildId: guildId, channelId: channelId) else {
            return .gatewayUnavailable
        }
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

    func noteReady(userId: String) {
        botUserId = userId
        state = .connected
        lastError = nil
    }

    func noteFailure(_ message: String) {
        state = .failed
        lastError = message
        logger.error("Discord bridge failure: \(message)")
    }
}

/// Callbacks from gateway handlers into the app engine (Sendable closures).
extension DiscordBridge {
    /// Begins correlation before Gateway opcode 4 is sent.
    private func beginVoiceGatewayHandshake(guildId: String, channelId: String) -> Bool {
        guard let botUserId else { return false }
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.begin(guildID: guildId, channelID: channelId, userID: botUserId)
        return true
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
