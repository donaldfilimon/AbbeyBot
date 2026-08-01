import Foundation

/// Pure Voice Gateway v8 sequencing. Networking and timers remain transport concerns.
public struct VoiceGatewayV8StateMachine: Sendable {
    public enum Phase: Equatable, Sendable {
        case disconnected
        case awaitingHello
        case awaitingReady
        case ready
        case awaitingSessionDescription
        case established
        case resuming
        case reconnectRequired
        case terminated
    }

    public enum CloseDisposition: Equatable, Sendable {
        case resume
        case reidentify
        case terminal

        /// Discord Voice close codes with conservative handling for unknown protocol failures.
        public static func classify(code: Int, resumeEligible: Bool) -> Self {
            switch code {
            case 4004, 4014, 1000:
                return .terminal
            case 4015, 1001, 1006:
                return resumeEligible ? .resume : .reidentify
            case 4001, 4002, 4003, 4005, 4006, 4009, 4011, 4012, 4016, 4017, 4018:
                return .reidentify
            default:
                // Unknown application close codes are terminal to avoid an unbounded reconnect loop.
                return (1000..<4000).contains(code) && resumeEligible ? .resume : .terminal
            }
        }
    }

    public private(set) var phase: Phase = .disconnected
    public private(set) var lastReceivedSequence: Int?
    public private(set) var readyPayload: VoiceGatewayV8Ready?
    public private(set) var pendingHeartbeatTimestamp: UInt64?
    public private(set) var nextHeartbeatAt: UInt64?
    public private(set) var heartbeatACKDeadline: UInt64?
    public private(set) var resumeEligible = false

    private let identity: VoiceGatewayV8Identify
    private var heartbeatInterval: UInt64?
    private var selectedMode: String?
    private var openingAsResume = false

    public init(identity: VoiceGatewayV8Identify) {
        self.identity = identity
    }

    /// Call after the separate Voice Gateway WebSocket opens.
    public mutating func opened(resuming: Bool = false) throws -> VoiceGatewayV8Outbound {
        guard phase == .disconnected || phase == .reconnectRequired else {
            throw VoiceGatewayV8Error.unexpectedEvent
        }
        let openingMessage: VoiceGatewayV8Outbound = if resuming {
            .resume(try resumePayload())
        } else {
            .identify(identity)
        }
        openingAsResume = resuming
        phase = .awaitingHello
        heartbeatInterval = nil
        pendingHeartbeatTimestamp = nil
        nextHeartbeatAt = nil
        heartbeatACKDeadline = nil
        return openingMessage
    }

    public mutating func receive(
        _ event: VoiceGatewayV8Inbound,
        nowMilliseconds: UInt64
    ) throws {
        if let sequence = event.sequence {
            guard sequence >= 0 else { throw VoiceGatewayV8Error.invalidSequence }
            if lastReceivedSequence == nil || sequence > lastReceivedSequence! {
                lastReceivedSequence = sequence
            }
        }

        switch event.payload {
        case .hello(let hello):
            guard phase == .awaitingHello else { throw VoiceGatewayV8Error.unexpectedEvent }
            heartbeatInterval = hello.heartbeatInterval
            nextHeartbeatAt = nowMilliseconds.addingReportingOverflow(hello.heartbeatInterval).overflow
                ? UInt64.max
                : nowMilliseconds + hello.heartbeatInterval
            phase = openingAsResume ? .resuming : .awaitingReady

        case .heartbeatACK(let acknowledgement):
            guard let pendingHeartbeatTimestamp else {
                throw VoiceGatewayV8Error.heartbeatAcknowledgementMismatch
            }
            guard acknowledgement.t == pendingHeartbeatTimestamp else {
                throw VoiceGatewayV8Error.heartbeatAcknowledgementMismatch
            }
            self.pendingHeartbeatTimestamp = nil
            heartbeatACKDeadline = nil

        case .ready(let ready):
            guard phase == .awaitingReady else { throw VoiceGatewayV8Error.unexpectedEvent }
            readyPayload = ready
            resumeEligible = true
            phase = .ready

        case .sessionDescription(let description):
            guard phase == .awaitingSessionDescription,
                  description.mode == selectedMode,
                  description.daveProtocolVersion == 0
            else {
                throw description.daveProtocolVersion == 0
                    ? VoiceGatewayV8Error.invalidEncryptionMode
                    : VoiceGatewayV8Error.unsupportedDAVEVersion(description.daveProtocolVersion)
            }
            phase = .established
            resumeEligible = true

        case .resumed:
            guard phase == .resuming else { throw VoiceGatewayV8Error.unexpectedEvent }
            phase = .established
            resumeEligible = true
        }
    }

    /// Produces a heartbeat when due and fails the connection when the prior ACK timed out.
    public mutating func heartbeatIfDue(nowMilliseconds: UInt64) throws -> VoiceGatewayV8Outbound? {
        guard let heartbeatInterval, let nextHeartbeatAt else { return nil }
        if pendingHeartbeatTimestamp != nil {
            if let heartbeatACKDeadline, nowMilliseconds >= heartbeatACKDeadline {
                phase = .reconnectRequired
                throw VoiceGatewayV8Error.missedHeartbeatAcknowledgement
            }
            return nil
        }
        guard nowMilliseconds >= nextHeartbeatAt else { return nil }

        let heartbeat = try VoiceGatewayV8Heartbeat(
            t: nowMilliseconds,
            sequenceAcknowledgement: lastReceivedSequence
        )
        pendingHeartbeatTimestamp = nowMilliseconds
        heartbeatACKDeadline = nowMilliseconds.addingReportingOverflow(heartbeatInterval).overflow
            ? UInt64.max
            : nowMilliseconds + heartbeatInterval
        self.nextHeartbeatAt = heartbeatACKDeadline
        return .heartbeat(heartbeat)
    }

    public mutating func selectProtocol(
        address: String,
        port: UInt16,
        mode: String
    ) throws -> VoiceGatewayV8Outbound {
        guard phase == .ready, let readyPayload else {
            throw VoiceGatewayV8Error.unexpectedEvent
        }
        guard readyPayload.modes.contains(mode) else {
            throw VoiceGatewayV8Error.invalidEncryptionMode
        }
        let selection = try VoiceGatewayV8SelectProtocol(address: address, port: port, mode: mode)
        selectedMode = mode
        phase = .awaitingSessionDescription
        return .selectProtocol(selection)
    }

    public func speaking(flags: Int, delay: Int = 0) throws -> VoiceGatewayV8Outbound {
        guard phase == .established, let ssrc = readyPayload?.ssrc else {
            throw VoiceGatewayV8Error.unexpectedEvent
        }
        return .speaking(try VoiceGatewayV8Speaking(speaking: flags, delay: delay, ssrc: ssrc))
    }

    public func resumePayload() throws -> VoiceGatewayV8Resume {
        guard resumeEligible, let lastReceivedSequence else { throw VoiceGatewayV8Error.resumeUnavailable }
        return try VoiceGatewayV8Resume(
            serverID: identity.serverID,
            sessionID: identity.sessionID,
            token: identity.token,
            sequenceAcknowledgement: lastReceivedSequence
        )
    }

    @discardableResult
    public mutating func handleClose(code: Int) -> CloseDisposition {
        let disposition = CloseDisposition.classify(code: code, resumeEligible: resumeEligible)
        pendingHeartbeatTimestamp = nil
        heartbeatACKDeadline = nil
        nextHeartbeatAt = nil
        switch disposition {
        case .resume:
            phase = .reconnectRequired
        case .reidentify:
            phase = .disconnected
            resumeEligible = false
            lastReceivedSequence = nil
            readyPayload = nil
            selectedMode = nil
        case .terminal:
            phase = .terminated
            resumeEligible = false
        }
        return disposition
    }
}
