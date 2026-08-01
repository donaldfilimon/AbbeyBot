import Foundation

protocol DiscordVoiceRetainedUDPSession: Sendable {
    func open() async throws
    func discover(
        ssrc: UInt32,
        deadline: ContinuousClock.Instant?
    ) async throws -> DiscordVoiceUDPDiscoveryResult
    func close() async
}

extension DiscordVoiceUDPSession: DiscordVoiceRetainedUDPSession {}

/// Adapts the persistent UDP media socket to the controller's discovery contract.
///
/// The adapter is intentionally single-use. Discord reports the NAT mapping for the socket used
/// by discovery, so replacing that socket before protected media begins would invalidate the
/// selected transport endpoint.
public actor DiscordVoiceUDPSessionAdapter: DiscordVoiceUDPDiscoverySession,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public enum AdapterError: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidReadyPayload
        case alreadyStarted
        case disconnected
        case transportFailure

        public var description: String {
            switch self {
            case .invalidReadyPayload:
                "Discord voice UDP Ready payload was invalid"
            case .alreadyStarted:
                "Discord voice UDP discovery session is single-use"
            case .disconnected:
                "Discord voice UDP discovery session was disconnected"
            case .transportFailure:
                "Discord voice UDP discovery transport failed"
            }
        }
    }

    public enum State: String, Equatable, Sendable {
        case idle
        case discovering
        case ready
        case failed
        case disconnected
    }

    public struct Snapshot: Equatable, Sendable, CustomStringConvertible {
        public let state: State
        public let retainedSocket: Bool

        public var description: String {
            "DiscordVoiceUDPSessionAdapter.Snapshot(state: \(state.rawValue), retainedSocket: \(retainedSocket))"
        }
    }

    typealias SessionBuilder = @Sendable (
        _ configuration: DiscordVoiceUDPSession.Configuration
    ) -> any DiscordVoiceRetainedUDPSession

    private nonisolated let safeDescription =
        "DiscordVoiceUDPSessionAdapter(endpoint: <redacted>)"
    private let discoveryTimeout: Duration
    private let makeSession: SessionBuilder
    private var state: State = .idle
    private var retainedSession: (any DiscordVoiceRetainedUDPSession)?

    public init(discoveryTimeout: Duration = .seconds(5)) {
        self.discoveryTimeout = discoveryTimeout
        self.makeSession = { DiscordVoiceUDPSession(configuration: $0) }
    }

    init(
        discoveryTimeout: Duration = .seconds(5),
        makeSession: @escaping SessionBuilder
    ) {
        self.discoveryTimeout = discoveryTimeout
        self.makeSession = makeSession
    }

    public nonisolated var description: String { safeDescription }
    public nonisolated var debugDescription: String { safeDescription }
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["endpoint": "<redacted>"], displayStyle: .class)
    }

    public func snapshot() -> Snapshot {
        Snapshot(state: state, retainedSocket: retainedSession != nil)
    }

    public func discoverEndpoint(
        for ready: DiscordVoiceGatewayTransportReady
    ) async throws -> DiscordVoiceDiscoveredEndpoint {
        guard !Task.isCancelled else { throw CancellationError() }
        guard state == .idle else {
            if state == .disconnected { throw AdapterError.disconnected }
            throw AdapterError.alreadyStarted
        }
        guard !ready.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ready.port > 0,
              discoveryTimeout > .zero
        else {
            state = .failed
            throw AdapterError.invalidReadyPayload
        }

        let configuration = DiscordVoiceUDPSession.Configuration(
            serverAddress: ready.address,
            serverPort: Int(ready.port),
            discoveryTimeout: discoveryTimeout
        )
        let session = makeSession(configuration)
        retainedSession = session
        state = .discovering

        return try await withTaskCancellationHandler {
            do {
                try await session.open()
                try Task.checkCancellation()
                let result = try await session.discover(
                    ssrc: ready.ssrc,
                    deadline: nil
                )
                try Task.checkCancellation()
                guard state == .discovering else { throw AdapterError.disconnected }
                state = .ready
                return DiscordVoiceDiscoveredEndpoint(
                    address: result.address,
                    port: result.port
                )
            } catch {
                if Task.isCancelled {
                    await disconnect()
                    throw CancellationError()
                }
                guard state != .disconnected else {
                    throw AdapterError.disconnected
                }
                state = .failed
                retainedSession = nil
                await session.close()
                if let adapterError = error as? AdapterError {
                    throw adapterError
                }
                throw AdapterError.transportFailure
            }
        } onCancel: {
            Task { await self.disconnect() }
        }
    }

    /// Closes the retained socket. Repeated teardown is harmless.
    public func disconnect() async {
        guard state != .disconnected else { return }
        state = .disconnected
        let session = retainedSession
        retainedSession = nil
        await session?.close()
    }
}

/// Portable voice factory: signaling and UDP discovery exist, but native DAVE/AEAD/Opus media
/// is not installed in AbbeyCore and therefore remains fail-closed.
public struct DiscordVoicePortableSessionFactory: DiscordVoiceSessionFactory, Sendable {
    public typealias GatewayConstructor = @Sendable () -> any DiscordVoiceGatewaySessionClient
    public typealias UDPConstructor = @Sendable () -> any DiscordVoiceUDPDiscoverySession

    private let makeGateway: GatewayConstructor
    private let makeUDP: UDPConstructor

    public let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability = .unavailable

    public init(
        gatewayConstructor: @escaping GatewayConstructor = {
            DiscordVoiceGatewaySession(mediaAttestation: .portableUnavailable)
        },
        udpConstructor: @escaping UDPConstructor = {
            DiscordVoiceUDPSessionAdapter()
        }
    ) {
        self.makeGateway = gatewayConstructor
        self.makeUDP = udpConstructor
    }

    public func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient {
        makeGateway()
    }

    public func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession {
        makeUDP()
    }
}
