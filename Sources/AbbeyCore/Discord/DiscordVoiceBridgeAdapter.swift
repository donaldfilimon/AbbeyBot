public enum DiscordVoiceBridgeAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    case gatewayUnavailable
    case requestInProgress
    case invalidIdentifiers

    public var description: String {
        switch self {
        case .gatewayUnavailable:
            "Discord Gateway is unavailable"
        case .requestInProgress:
            "A Discord voice-state request is already in progress"
        case .invalidIdentifiers:
            "Discord voice identifiers are invalid"
        }
    }
}

/// Adapts the main Discord Gateway actor to the portable media controller.
/// Ephemeral Voice Gateway credentials are consumed exactly once and are never
/// persisted, logged, or exposed to the desktop view layer.
public struct DiscordVoiceBridgeAdapter: DiscordVoiceGatewayPairBridge, Sendable {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let requestImpl: @Sendable (String, String) async -> VoiceUpdateResult
    private let consumeImpl: @Sendable () async -> VoiceGatewayHandshake.Credentials?
    private let leaveImpl: @Sendable (String) async -> Void
    private let pollInterval: Duration
    private let sleeper: Sleeper

    public init(
        bridge: DiscordBridge,
        pollInterval: Duration = .milliseconds(10)
    ) {
        self.requestImpl = { guildID, channelID in
            await bridge.joinVoice(guildId: guildID, channelId: channelID)
        }
        self.consumeImpl = {
            await bridge.consumeVoiceGatewayCredentials()
        }
        self.leaveImpl = { guildID in
            _ = await bridge.leaveVoice(guildId: guildID)
        }
        self.pollInterval = max(.milliseconds(1), pollInterval)
        self.sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(
        pollInterval: Duration = .milliseconds(1),
        sleeper: @escaping Sleeper = { duration in try await Task.sleep(for: duration) },
        request: @escaping @Sendable (String, String) async -> VoiceUpdateResult,
        consume: @escaping @Sendable () async -> VoiceGatewayHandshake.Credentials?,
        leave: @escaping @Sendable (String) async -> Void
    ) {
        self.requestImpl = request
        self.consumeImpl = consume
        self.leaveImpl = leave
        self.pollInterval = max(.milliseconds(1), pollInterval)
        self.sleeper = sleeper
    }

    public func requestGatewayState(guildID: String, channelID: String) async throws {
        switch await requestImpl(guildID, channelID) {
        case .requested:
            return
        case .gatewayUnavailable:
            throw DiscordVoiceBridgeAdapterError.gatewayUnavailable
        case .requestInProgress:
            throw DiscordVoiceBridgeAdapterError.requestInProgress
        case .invalidIdentifiers:
            throw DiscordVoiceBridgeAdapterError.invalidIdentifiers
        }
    }

    public func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair {
        while true {
            try Task.checkCancellation()
            if let credentials = await consumeImpl() {
                return DiscordVoiceGatewayPair(
                    endpoint: credentials.endpoint,
                    token: credentials.token,
                    sessionID: credentials.sessionID,
                    serverID: credentials.guildID,
                    channelID: credentials.channelID,
                    userID: credentials.userID
                )
            }
            try await sleeper(pollInterval)
        }
    }

    public func leaveVoice(guildID: String) async {
        await leaveImpl(guildID)
    }
}
