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
    private let attempts: DiscordVoiceJoinAttemptBroker

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
        self.attempts = DiscordVoiceJoinAttemptBroker()
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
        self.attempts = DiscordVoiceJoinAttemptBroker()
    }

    public func requestGatewayState(guildID: String, channelID: String) async throws {
        let attempt = await attempts.begin(guildID: guildID, channelID: channelID)
        switch await requestImpl(guildID, channelID) {
        case .requested:
            return
        case .gatewayUnavailable:
            await attempts.cancelIfCurrent(attempt)
            throw DiscordVoiceBridgeAdapterError.gatewayUnavailable
        case .requestInProgress:
            await attempts.cancelIfCurrent(attempt)
            throw DiscordVoiceBridgeAdapterError.requestInProgress
        case .invalidIdentifiers:
            await attempts.cancelIfCurrent(attempt)
            throw DiscordVoiceBridgeAdapterError.invalidIdentifiers
        }
    }

    public func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair {
        guard let attempt = await attempts.current() else {
            throw CancellationError()
        }
        while true {
            try Task.checkCancellation()
            switch await attempts.next(for: attempt) {
            case .stale:
                throw CancellationError()
            case .pair(let credentials):
                return DiscordVoiceGatewayPair(
                    endpoint: credentials.endpoint,
                    token: credentials.token,
                    sessionID: credentials.sessionID,
                    serverID: credentials.guildID,
                    channelID: credentials.channelID,
                    userID: credentials.userID
                )
            case .poll:
                let credentials = await consumeImpl()
                switch await attempts.finishPoll(for: attempt, credentials: credentials) {
                case .stale:
                    throw CancellationError()
                case .retry:
                    break
                case .pair(let credentials):
                    return DiscordVoiceGatewayPair(
                        endpoint: credentials.endpoint,
                        token: credentials.token,
                        sessionID: credentials.sessionID,
                        serverID: credentials.guildID,
                        channelID: credentials.channelID,
                        userID: credentials.userID
                    )
                }
            case .wait:
                break
            }
            try await sleeper(pollInterval)
        }
    }

    public func leaveVoice(guildID: String) async {
        await leaveImpl(guildID)
    }
}

private struct DiscordVoiceJoinAttempt: Equatable, Sendable {
    let generation: UInt64
    let guildID: String
    let channelID: String
}

private enum DiscordVoiceJoinAttemptDirective: Sendable {
    case stale
    case pair(VoiceGatewayHandshake.Credentials)
    case poll
    case wait
}

private enum DiscordVoiceJoinAttemptPollResult: Sendable {
    case stale
    case retry
    case pair(VoiceGatewayHandshake.Credentials)
}

/// Routes one-shot credentials to the join attempt that requested their
/// guild/channel pair. The actor deliberately retains no superseded pair.
private actor DiscordVoiceJoinAttemptBroker {
    private var generation: UInt64 = 0
    private var active: DiscordVoiceJoinAttempt?
    private var pending: VoiceGatewayHandshake.Credentials?
    private var pollingGeneration: UInt64?

    func begin(guildID: String, channelID: String) -> DiscordVoiceJoinAttempt {
        generation &+= 1
        let attempt = DiscordVoiceJoinAttempt(
            generation: generation,
            guildID: guildID,
            channelID: channelID
        )
        active = attempt
        pending = nil
        // The old consumer may still return, but it no longer owns the poll
        // lease. Its result will be routed by target below instead.
        pollingGeneration = nil
        return attempt
    }

    func cancelIfCurrent(_ attempt: DiscordVoiceJoinAttempt) {
        guard active == attempt else { return }
        active = nil
        pending = nil
        pollingGeneration = nil
    }

    func current() -> DiscordVoiceJoinAttempt? {
        active
    }

    func next(for attempt: DiscordVoiceJoinAttempt) -> DiscordVoiceJoinAttemptDirective {
        guard active == attempt else { return .stale }
        if let pending {
            self.pending = nil
            return .pair(pending)
        }
        guard pollingGeneration == nil else { return .wait }
        pollingGeneration = attempt.generation
        return .poll
    }

    func finishPoll(
        for attempt: DiscordVoiceJoinAttempt,
        credentials: VoiceGatewayHandshake.Credentials?
    ) -> DiscordVoiceJoinAttemptPollResult {
        if pollingGeneration == attempt.generation {
            pollingGeneration = nil
        }
        guard let credentials else {
            return active == attempt ? .retry : .stale
        }
        guard let active, credentials.guildID == active.guildID,
            credentials.channelID == active.channelID
        else {
            // A late credential for a superseded target is consumed and
            // forgotten. It must never become eligible for a later join.
            return self.active == attempt ? .retry : .stale
        }
        if active == attempt {
            return .pair(credentials)
        }
        pending = credentials
        return .stale
    }
}
