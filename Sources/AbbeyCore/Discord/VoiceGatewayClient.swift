import Dispatch
import Foundation

public enum VoiceGatewayClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyRunning
    case mediaHandoffUnavailable
    case outboundPayloadTooLarge
    case outboundEncodingFailed
    case reconnectLimitReached

    public var description: String {
        switch self {
        case .alreadyRunning: "Discord Voice Gateway client is already running"
        case .mediaHandoffUnavailable: "Discord UDP discovery and protocol selection are unavailable"
        case .outboundPayloadTooLarge: "Discord Voice Gateway outbound payload exceeded its limit"
        case .outboundEncodingFailed: "Discord Voice Gateway outbound payload could not be encoded"
        case .reconnectLimitReached: "Discord Voice Gateway reconnect limit was reached"
        }
    }
}

public struct VoiceGatewayUDPSelection: Equatable, Sendable {
    public let address: String
    public let port: UInt16
    public let mode: String

    public init(address: String, port: UInt16, mode: String) {
        self.address = address
        self.port = port
        self.mode = mode
    }
}

/// Injected boundary for UDP discovery and encryption-mode negotiation.
public struct VoiceGatewayUDPHandoff: Sendable {
    public typealias Prepare = @Sendable (VoiceGatewayV8Ready) async throws -> VoiceGatewayUDPSelection
    private let prepareImpl: Prepare

    public init(prepare: @escaping Prepare) {
        self.prepareImpl = prepare
    }

    public func prepare(for ready: VoiceGatewayV8Ready) async throws -> VoiceGatewayUDPSelection {
        try await prepareImpl(ready)
    }

    public static let unavailable = Self { _ in
        throw VoiceGatewayClientError.mediaHandoffUnavailable
    }
}

public struct VoiceGatewayClientClock: Sendable {
    public typealias Now = @Sendable () async -> UInt64
    public typealias Sleep = @Sendable (UInt64) async throws -> Void

    private let nowImpl: Now
    private let sleepImpl: Sleep

    public init(now: @escaping Now, sleep: @escaping Sleep) {
        self.nowImpl = now
        self.sleepImpl = sleep
    }

    public func nowMilliseconds() async -> UInt64 { await nowImpl() }
    public func sleep(milliseconds: UInt64) async throws { try await sleepImpl(milliseconds) }

    public static let continuous = Self(
        now: { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
        sleep: { milliseconds in
            let bounded = min(milliseconds, UInt64(Int64.max))
            try await Task.sleep(for: .milliseconds(Int64(bounded)))
        }
    )
}

public actor VoiceGatewayClient: CustomStringConvertible, CustomDebugStringConvertible {
    public struct Configuration: Equatable, Sendable {
        public var maximumMessageBytes: Int
        public var maximumReconnectAttempts: Int
        public var idleHeartbeatPollMilliseconds: UInt64

        public init(
            maximumMessageBytes: Int = VoiceGatewayV8Decoder.maximumPayloadBytes,
            maximumReconnectAttempts: Int = 3,
            idleHeartbeatPollMilliseconds: UInt64 = 25
        ) {
            self.maximumMessageBytes = min(max(1, maximumMessageBytes), VoiceGatewayV8Decoder.maximumPayloadBytes)
            self.maximumReconnectAttempts = min(max(0, maximumReconnectAttempts), 10)
            self.idleHeartbeatPollMilliseconds = min(max(1, idleHeartbeatPollMilliseconds), 1_000)
        }
    }

    public enum Outcome: Equatable, Sendable {
        case disconnected
        case terminalClose(Int)
        case reconnectLimitReached
    }

    public struct Snapshot: Equatable, Sendable {
        public let phase: VoiceGatewayV8StateMachine.Phase
        public let lastReceivedSequence: Int?
        public let resumeEligible: Bool
        public let explicitlyDisconnected: Bool
    }

    private let endpoint: VoiceGatewayV8Endpoint
    private nonisolated let safeDescription: String
    private let transport: VoiceGatewayClientTransport
    private let udpHandoff: VoiceGatewayUDPHandoff
    private let clock: VoiceGatewayClientClock
    private let configuration: Configuration
    private var machine: VoiceGatewayV8StateMachine
    private var activeSession: VoiceGatewayClientSession?
    private var explicitlyDisconnected = false
    private var running = false

    public init(
        endpoint: VoiceGatewayV8Endpoint,
        identity: VoiceGatewayV8Identify,
        transport: VoiceGatewayClientTransport = .live(),
        udpHandoff: VoiceGatewayUDPHandoff = .unavailable,
        clock: VoiceGatewayClientClock = .continuous,
        configuration: Configuration = .init()
    ) {
        self.endpoint = endpoint
        self.safeDescription = "VoiceGatewayClient(endpoint: \(endpoint), credentials: <redacted>)"
        self.transport = transport
        self.udpHandoff = udpHandoff
        self.clock = clock
        self.configuration = configuration
        self.machine = VoiceGatewayV8StateMachine(identity: identity)
    }

    public nonisolated var description: String { safeDescription }
    public nonisolated var debugDescription: String { safeDescription }

    public func snapshot() -> Snapshot {
        Snapshot(
            phase: machine.phase,
            lastReceivedSequence: machine.lastReceivedSequence,
            resumeEligible: machine.resumeEligible,
            explicitlyDisconnected: explicitlyDisconnected
        )
    }

    public func connect() async throws -> Outcome {
        guard !running else { throw VoiceGatewayClientError.alreadyRunning }
        running = true
        explicitlyDisconnected = false
        defer {
            running = false
            activeSession = nil
        }

        var reconnectAttempts = 0
        var shouldResume = false
        while true {
            let resumeThisAttempt = shouldResume
            let close: VoiceGatewayClientClose?
            do {
                close = try await transport.run(
                    endpoint: endpoint,
                    maximumMessageBytes: configuration.maximumMessageBytes
                ) { session in
                    try await self.runSession(session, resuming: resumeThisAttempt)
                }
            } catch is CancellationError {
                if explicitlyDisconnected { return .disconnected }
                throw CancellationError()
            } catch let error as VoiceGatewayClientTransportError {
                if explicitlyDisconnected { return .disconnected }
                switch error {
                case .binaryMessageRejected, .messageTooLarge, .invalidTextEncoding:
                    throw error
                case .connectionClosed:
                    close = VoiceGatewayClientClose(code: 1006, reason: nil)
                }
            } catch VoiceGatewayV8Error.missedHeartbeatAcknowledgement {
                if explicitlyDisconnected { return .disconnected }
                close = VoiceGatewayClientClose(code: 1006, reason: nil)
            } catch {
                if explicitlyDisconnected { return .disconnected }
                close = VoiceGatewayClientClose(code: 1006, reason: nil)
            }

            if explicitlyDisconnected { return .disconnected }
            let code = close?.code ?? 1006
            let disposition = machine.handleClose(code: code)
            switch disposition {
            case .terminal:
                return .terminalClose(code)
            case .resume, .reidentify:
                guard reconnectAttempts < configuration.maximumReconnectAttempts else {
                    return .reconnectLimitReached
                }
                reconnectAttempts += 1
                shouldResume = disposition == .resume
            }
        }
    }

    /// Explicit operator disconnect always wins over a simultaneous resumable close.
    public func disconnect() async {
        explicitlyDisconnected = true
        if let activeSession {
            await activeSession.close(code: 1000, reason: "operator disconnect")
        }
    }

    private func runSession(
        _ session: VoiceGatewayClientSession,
        resuming: Bool
    ) async throws {
        guard !explicitlyDisconnected else {
            await session.close(code: 1000, reason: "operator disconnect")
            return
        }
        activeSession = session
        do {
            try await send(try machine.opened(resuming: resuming), through: session)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.receiveLoop(session)
                }
                group.addTask {
                    try await self.heartbeatLoop(session)
                }
                _ = try await group.next()
                group.cancelAll()
                while await group.nextResult() != nil {}
            }
            activeSession = nil
        } catch {
            activeSession = nil
            throw error
        }
    }

    private func receiveLoop(_ session: VoiceGatewayClientSession) async throws {
        while !Task.isCancelled, let text = try await session.receive() {
            guard text.utf8.count <= configuration.maximumMessageBytes else {
                await session.close(code: 1009, reason: "message too large")
                throw VoiceGatewayClientTransportError.messageTooLarge
            }
            let event = try VoiceGatewayV8Decoder.decode(Data(text.utf8))
            let now = await clock.nowMilliseconds()
            try machine.receive(event, nowMilliseconds: now)

            if case .ready(let ready) = event.payload {
                let selection = try await udpHandoff.prepare(for: ready)
                let outbound = try machine.selectProtocol(
                    address: selection.address,
                    port: selection.port,
                    mode: selection.mode
                )
                try await send(outbound, through: session)
            }
        }
    }

    private func heartbeatLoop(_ session: VoiceGatewayClientSession) async throws {
        while !Task.isCancelled {
            let now = await clock.nowMilliseconds()
            do {
                if let heartbeat = try machine.heartbeatIfDue(nowMilliseconds: now) {
                    try await send(heartbeat, through: session)
                }
            } catch VoiceGatewayV8Error.missedHeartbeatAcknowledgement {
                await session.close(code: 1001, reason: "heartbeat ACK timeout")
                throw VoiceGatewayV8Error.missedHeartbeatAcknowledgement
            }

            let delay: UInt64
            if let due = machine.nextHeartbeatAt, due > now {
                delay = min(due - now, configuration.idleHeartbeatPollMilliseconds)
            } else {
                delay = configuration.idleHeartbeatPollMilliseconds
            }
            try await clock.sleep(milliseconds: delay)
        }
    }

    private func send(
        _ outbound: VoiceGatewayV8Outbound,
        through session: VoiceGatewayClientSession
    ) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(outbound)
        } catch {
            throw VoiceGatewayClientError.outboundEncodingFailed
        }
        guard data.count <= configuration.maximumMessageBytes else {
            throw VoiceGatewayClientError.outboundPayloadTooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceGatewayClientError.outboundEncodingFailed
        }
        try await session.send(text)
    }
}
