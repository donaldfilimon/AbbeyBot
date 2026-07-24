import Foundation
import DiscordBM
import Logging

public enum DiscordConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case failed
}

/// Owns the DiscordBM gateway manager and exposes connect/disconnect for the desktop app.
public actor DiscordBridge {
    public private(set) var state: DiscordConnectionState = .disconnected
    public private(set) var lastError: String?
    public private(set) var botUserId: String?

    private var gateway: BotGatewayManager?
    private var eventTask: Task<Void, Never>?
    private let logger = Logger(label: "AbbeyBot.DiscordBridge")

    public init() {}

    public var client: (any DiscordClient)? {
        gateway?.client
    }

    public func connect(
        token: String,
        hooks: DiscordEventHooks
    ) async {
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
                activities: [.init(name: "AbbeyBot desktop", type: .listening)],
                status: .online,
                afk: false
            ),
            intents: [
                .guildMessages,
                .messageContent,
                .guildMembers,
                .directMessages,
                .guildMessageReactions
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
        eventTask?.cancel()
        eventTask = nil
        // BotGatewayManager has no explicit disconnect API in all versions — drop reference.
        gateway = nil
        state = .disconnected
        botUserId = nil
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
