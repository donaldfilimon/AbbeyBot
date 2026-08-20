import Foundation

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

    private let requestImpl: @Sendable (String, String) async -> DiscordVoiceGatewayPairRequestOutcome
    private let consumeImpl: @Sendable (VoiceGatewayHandshake.Generation) async -> VoiceGatewayHandshake.Credentials?
    private let leaveImpl: @Sendable (String) async -> Void
    private let presenceImpl: @Sendable () async -> Bool
    private let pollInterval: Duration
    private let sleeper: Sleeper
    private let attempts: DiscordVoiceJoinAttemptBroker

    public init(
        bridge: DiscordBridge,
        pollInterval: Duration = .milliseconds(10)
    ) {
        self.requestImpl = { guildID, channelID in
            await bridge.requestVoiceGatewayPair(guildId: guildID, channelId: channelID)
        }
        self.consumeImpl = { generation in
            await bridge.consumeVoiceGatewayCredentials(for: generation)
        }
        self.leaveImpl = { guildID in
            _ = await bridge.leaveVoiceAndWaitForAcknowledgement(guildId: guildID)
        }
        self.presenceImpl = {
            // Discord's own self VOICE_STATE_UPDATE echo is the authority:
            // a kick or channel removal clears the bridge's confirmed
            // presence, which the controller's reconnect fallback reads as
            // "do not rejoin".
            await bridge.voicePresenceState().confirmedInChannel
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
        request: @escaping @Sendable (String, String) async -> DiscordVoiceGatewayPairRequestOutcome,
        consume: @escaping @Sendable (VoiceGatewayHandshake.Generation) async -> VoiceGatewayHandshake.Credentials?,
        leave: @escaping @Sendable (String) async -> Void,
        presence: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.requestImpl = request
        self.consumeImpl = consume
        self.leaveImpl = leave
        self.presenceImpl = presence
        self.pollInterval = max(.milliseconds(1), pollInterval)
        self.sleeper = sleeper
        self.attempts = DiscordVoiceJoinAttemptBroker()
    }

    public func voicePresenceHeld() async -> Bool {
        await presenceImpl()
    }

    public func requestGatewayState(guildID: String, channelID: String) async throws {
        let canonicalGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestTicket = await attempts.beginRequest(
            guildID: canonicalGuildID,
            channelID: canonicalChannelID
        )
        let outcome = await requestImpl(canonicalGuildID, canonicalChannelID)
        let committed = await attempts.finishRequest(
            requestTicket,
            outcome: outcome
        )
        switch outcome {
        case .requested:
            guard committed else {
                // The bridge can accept after a concurrent leave tombstones
                // this provisional ticket. Release that producer-owned
                // allocation before reporting cancellation so it cannot be
                // resurrected outside the broker.
                await leaveImpl(canonicalGuildID)
                throw CancellationError()
            }
            return
        case .cancelled:
            throw CancellationError()
        case .gatewayUnavailable:
            throw DiscordVoiceBridgeAdapterError.gatewayUnavailable
        case .requestInProgress:
            throw DiscordVoiceBridgeAdapterError.requestInProgress
        case .invalidIdentifiers:
            throw DiscordVoiceBridgeAdapterError.invalidIdentifiers
        }
    }

    public func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair {
        guard let attempt = await attempts.claimCurrent() else {
            throw CancellationError()
        }
        do {
            while true {
                try Task.checkCancellation()
                switch await attempts.next(for: attempt) {
                case .stale:
                    throw CancellationError()
                case .pair(let credentials):
                    try Task.checkCancellation()
                    return DiscordVoiceGatewayPair(
                        endpoint: credentials.endpoint,
                        token: credentials.token,
                        sessionID: credentials.sessionID,
                        serverID: credentials.guildID,
                        channelID: credentials.channelID,
                        userID: credentials.userID
                    )
                case .poll:
                    let credentials = await consumeImpl(attempt.generation)
                    let pollResult = await attempts.finishPoll(for: attempt, credentials: credentials)
                    try Task.checkCancellation()
                    switch pollResult {
                    case .stale:
                        throw CancellationError()
                    case .retry:
                        break
                    case .pair(let credentials):
                        try Task.checkCancellation()
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
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            await attempts.cancelIfCurrent(attempt)
            throw CancellationError()
        }
    }

    public func leaveVoice(guildID: String) async {
        let canonicalGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        await attempts.cancel(guildID: canonicalGuildID)
        await leaveImpl(canonicalGuildID)
    }
}

private struct DiscordVoiceAdapterRequestTicket: Equatable, Sendable {
    let value: UInt64
    let guildID: String
    let channelID: String
}

private struct DiscordVoiceJoinAttempt: Equatable, Sendable {
    let ticket: DiscordVoiceAdapterRequestTicket
    let generation: VoiceGatewayHandshake.Generation
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

/// Tracks adapter request completion order while treating the producer-issued
/// handshake generation as the sole credential identity.
private actor DiscordVoiceJoinAttemptBroker {
    private var nextRequestTicket: UInt64 = 0
    private var latestAcceptedTicket: UInt64 = 0
    private var provisionalByTicket: [UInt64: DiscordVoiceAdapterRequestTicket] = [:]
    private var active: DiscordVoiceJoinAttempt?
    private var pending: VoiceGatewayHandshake.Credentials?
    private var claimedTicket: DiscordVoiceAdapterRequestTicket?
    private var pollingTicket: DiscordVoiceAdapterRequestTicket?

    func beginRequest(guildID: String, channelID: String) -> DiscordVoiceAdapterRequestTicket {
        nextRequestTicket &+= 1
        let ticket = DiscordVoiceAdapterRequestTicket(
            value: nextRequestTicket,
            guildID: guildID,
            channelID: channelID
        )
        provisionalByTicket[ticket.value] = ticket
        return ticket
    }

    func finishRequest(
        _ ticket: DiscordVoiceAdapterRequestTicket,
        outcome: DiscordVoiceGatewayPairRequestOutcome
    ) -> Bool {
        guard provisionalByTicket.removeValue(forKey: ticket.value) == ticket else {
            return false
        }
        guard case .requested(let generation) = outcome else {
            // A rejected provisional replacement has no authority to retire an
            // already accepted attempt.
            return false
        }
        guard ticket.value > latestAcceptedTicket else { return false }
        latestAcceptedTicket = ticket.value
        active = DiscordVoiceJoinAttempt(
            ticket: ticket,
            generation: generation,
            guildID: ticket.guildID,
            channelID: ticket.channelID
        )
        pending = nil
        claimedTicket = nil
        pollingTicket = nil
        return true
    }

    func cancelIfCurrent(_ attempt: DiscordVoiceJoinAttempt) {
        guard active == attempt else { return }
        retire()
    }

    func cancel(guildID: String) {
        provisionalByTicket = provisionalByTicket.filter { $0.value.guildID != guildID }
        if active?.guildID == guildID {
            retire()
        }
    }

    func claimCurrent() -> DiscordVoiceJoinAttempt? {
        guard let active, claimedTicket == nil else { return nil }
        claimedTicket = active.ticket
        return active
    }

    func next(for attempt: DiscordVoiceJoinAttempt) -> DiscordVoiceJoinAttemptDirective {
        guard active == attempt else { return .stale }
        if let pending {
            retire()
            return .pair(pending)
        }
        guard pollingTicket == nil else { return .wait }
        pollingTicket = attempt.ticket
        return .poll
    }

    func finishPoll(
        for attempt: DiscordVoiceJoinAttempt,
        credentials: VoiceGatewayHandshake.Credentials?
    ) -> DiscordVoiceJoinAttemptPollResult {
        if pollingTicket == attempt.ticket {
            pollingTicket = nil
        }
        guard let credentials else {
            return active == attempt ? .retry : .stale
        }
        guard let active,
            credentials.generation == active.generation,
            credentials.guildID == active.guildID,
            credentials.channelID == active.channelID
        else {
            // A producer that violates generation-scoped consumption cannot
            // make a mismatched capability eligible for the active attempt.
            return self.active == attempt ? .retry : .stale
        }
        if active == attempt {
            retire()
            return .pair(credentials)
        }
        pending = credentials
        return .stale
    }

    private func retire() {
        active = nil
        pending = nil
        claimedTicket = nil
        pollingTicket = nil
    }
}
