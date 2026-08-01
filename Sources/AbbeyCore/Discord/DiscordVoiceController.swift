public struct DiscordVoiceGatewayPair: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let endpoint: String
    public let token: String
    public let sessionID: String
    public let serverID: String
    public let channelID: String
    public let userID: String

    public init(
        endpoint: String,
        token: String,
        sessionID: String,
        serverID: String,
        channelID: String,
        userID: String
    ) {
        self.endpoint = endpoint
        self.token = token
        self.sessionID = sessionID
        self.serverID = serverID
        self.channelID = channelID
        self.userID = userID
    }

    public var description: String { "DiscordVoiceGatewayPair(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["credentials": "<redacted>"], displayStyle: .struct)
    }
}

public struct DiscordVoiceGatewayTransportReady: Equatable, Sendable {
    public let address: String
    public let port: UInt16
    public let ssrc: UInt32
    public let encryptionModes: [String]

    public init(address: String, port: UInt16, ssrc: UInt32, encryptionModes: [String]) {
        self.address = address
        self.port = port
        self.ssrc = ssrc
        self.encryptionModes = encryptionModes
    }
}

public struct DiscordVoiceDiscoveredEndpoint: Equatable, Sendable {
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

public struct DiscordVoiceMediaCapabilities: Equatable, Sendable {
    public let dave: Bool
    public let aead: Bool
    public let opus: Bool

    public init(dave: Bool, aead: Bool, opus: Bool) {
        self.dave = dave
        self.aead = aead
        self.opus = opus
    }

    public var isProductionReady: Bool { dave && aead && opus }
}

public enum DiscordVoiceMediaAdapterAvailability: Equatable, Sendable {
    case unavailable
    case fullyWired
}

public protocol DiscordVoiceGatewayPairBridge: Sendable {
    func requestGatewayState(guildID: String, channelID: String) async throws
    func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair
    func leaveVoice(guildID: String) async
}

public protocol DiscordVoiceGatewaySessionClient: Sendable {
    func connect(using pair: DiscordVoiceGatewayPair) async throws -> DiscordVoiceGatewayTransportReady
    func selectTransport(_ endpoint: DiscordVoiceDiscoveredEndpoint) async throws
    func negotiateDAVEAndMedia() async throws -> DiscordVoiceMediaCapabilities
    func disconnect() async
}

public protocol DiscordVoiceUDPDiscoverySession: Sendable {
    func discoverEndpoint(for ready: DiscordVoiceGatewayTransportReady) async throws -> DiscordVoiceDiscoveredEndpoint
    func disconnect() async
}

public protocol DiscordVoiceSessionFactory: Sendable {
    var mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability { get }
    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession
}

public enum DiscordVoiceControllerPhase: String, Equatable, Sendable {
    case idle
    case requestingGatewayState
    case awaitingGatewayPair
    case connectingVoiceGateway
    case negotiatingTransport
    case negotiatingDAVE
    case readyMuted
    case readySpeaking
    case reconnecting
    case failed
}

public enum DiscordVoiceControllerFailure: String, Error, Equatable, Sendable {
    case credentialTimedOut
    case bridgeUnavailable
    case gatewayUnavailable
    case transportUnavailable
    case mediaUnavailable
}

/// Immutable and intentionally redacted. It contains no guild/channel/user IDs,
/// endpoint addresses, session IDs, tokens, encryption modes, or media bytes.
public struct DiscordVoiceControllerSnapshot: Equatable, Sendable, CustomStringConvertible {
    public let phase: DiscordVoiceControllerPhase
    public let generation: UInt64
    public let microphoneEnabled: Bool
    public let cameraEnabled: Bool
    public let screenShareEnabled: Bool
    public let queuedAudioFrames: Int
    public let queuedVideoFrames: Int
    public let droppedAudioFrames: UInt64
    public let droppedVideoFrames: UInt64
    public let failure: DiscordVoiceControllerFailure?
    public let mediaAdapterAvailable: Bool

    public var description: String {
        let failureDescription = failure?.rawValue ?? "none"
        return "DiscordVoiceControllerSnapshot(phase: \(phase.rawValue), generation: \(generation), microphone: \(microphoneEnabled), camera: \(cameraEnabled), screen: \(screenShareEnabled), audioQueued: \(queuedAudioFrames), videoQueued: \(queuedVideoFrames), failure: \(failureDescription), mediaAdapterAvailable: \(mediaAdapterAvailable))"
    }
}

public struct DiscordVoiceControllerConfiguration: Equatable, Sendable {
    public let credentialTimeout: Duration
    public let snapshotBufferLimit: Int
    public let audioQueueCapacity: Int
    public let videoQueueCapacity: Int

    public init(
        credentialTimeout: Duration = .seconds(10),
        snapshotBufferLimit: Int = 32,
        audioQueueCapacity: Int = 64,
        videoQueueCapacity: Int = 4
    ) throws {
        guard credentialTimeout > .zero else {
            throw DiscordVoiceMediaContractError.invalidCredentialTimeout
        }
        guard snapshotBufferLimit > 0 else {
            throw DiscordVoiceMediaContractError.invalidQueueCapacity(snapshotBufferLimit)
        }
        guard audioQueueCapacity > 0 else {
            throw DiscordVoiceMediaContractError.invalidQueueCapacity(audioQueueCapacity)
        }
        guard videoQueueCapacity > 0 else {
            throw DiscordVoiceMediaContractError.invalidQueueCapacity(videoQueueCapacity)
        }
        self.credentialTimeout = credentialTimeout
        self.snapshotBufferLimit = snapshotBufferLimit
        self.audioQueueCapacity = audioQueueCapacity
        self.videoQueueCapacity = videoQueueCapacity
    }
}

public enum DiscordVoiceFrameAdmission: Equatable, Sendable {
    case accepted
    case acceptedDroppingOldest
    case captureDisabled
    case staleGeneration
    case mediaNotReady
}

private struct DiscordVoiceJoinTarget: Sendable {
    let guildID: String
    let channelID: String
}

private enum DiscordVoicePairRaceResult: Sendable {
    case pair(DiscordVoiceGatewayPair)
    case failure
    case timeout
    case cancelled
}

/// Portable voice-session orchestration. Platform capture/playback and concrete
/// Discord adapters live outside this actor and enter only through Sendable
/// contracts. No reinforcement-learning path participates in session control.
public actor DiscordVoiceController {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let bridge: any DiscordVoiceGatewayPairBridge
    private let factory: any DiscordVoiceSessionFactory
    private let configuration: DiscordVoiceControllerConfiguration
    private let sleeper: Sleeper

    private var generation: UInt64 = 0
    private var phase: DiscordVoiceControllerPhase = .idle
    private var failure: DiscordVoiceControllerFailure?
    private var target: DiscordVoiceJoinTarget?
    private var gatewayClient: (any DiscordVoiceGatewaySessionClient)?
    private var udpSession: (any DiscordVoiceUDPDiscoverySession)?
    private var acceptsFrames = false

    private var microphoneEnabled = false
    private var cameraEnabled = false
    private var screenShareEnabled = false
    private var audioQueue: DiscordVoiceBoundedQueue<DiscordVoiceOwnedAudioFrame>
    private var videoQueue: DiscordVoiceBoundedQueue<DiscordVoiceOwnedVideoFrame>

    private var nextStreamID: UInt64 = 0
    private var snapshotContinuations: [UInt64: AsyncStream<DiscordVoiceControllerSnapshot>.Continuation] = [:]

    public init(
        bridge: any DiscordVoiceGatewayPairBridge,
        factory: any DiscordVoiceSessionFactory,
        configuration: DiscordVoiceControllerConfiguration,
        sleeper: @escaping Sleeper = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) throws {
        self.bridge = bridge
        self.factory = factory
        self.configuration = configuration
        self.sleeper = sleeper
        self.audioQueue = try DiscordVoiceBoundedQueue(capacity: configuration.audioQueueCapacity)
        self.videoQueue = try DiscordVoiceBoundedQueue(capacity: configuration.videoQueueCapacity)
    }

    public func currentSnapshot() -> DiscordVoiceControllerSnapshot {
        makeSnapshot()
    }

    public func snapshots() -> AsyncStream<DiscordVoiceControllerSnapshot> {
        nextStreamID &+= 1
        let streamID = nextStreamID
        let (stream, continuation) = AsyncStream.makeStream(
            of: DiscordVoiceControllerSnapshot.self,
            bufferingPolicy: .bufferingNewest(configuration.snapshotBufferLimit)
        )
        snapshotContinuations[streamID] = continuation
        continuation.yield(makeSnapshot())
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSnapshotContinuation(streamID) }
        }
        return stream
    }

    @discardableResult
    public func join(guildID: String, channelID: String) async -> DiscordVoiceControllerSnapshot {
        // A replacement join owns a fresh generation and cannot share the old
        // Gateway or UDP session. Teardown is awaited before requesting another
        // main-Gateway capability pair.
        let prior = invalidateAndDetach(clearTarget: true)
        transition(to: .idle)
        await prior.udp?.disconnect()
        await prior.gateway?.disconnect()
        if let guildID = prior.guildID {
            await prior.bridge.leaveVoice(guildID: guildID)
        }
        let localGeneration = beginGeneration(
            target: DiscordVoiceJoinTarget(guildID: guildID, channelID: channelID),
            initialPhase: .requestingGatewayState
        )
        return await runJoin(generation: localGeneration)
    }

    @discardableResult
    public func reconnect() async -> DiscordVoiceControllerSnapshot {
        guard let target else { return makeSnapshot() }
        let oldGateway = gatewayClient
        let oldUDP = udpSession
        let localGeneration = beginGeneration(target: target, initialPhase: .reconnecting)
        gatewayClient = nil
        udpSession = nil
        await oldUDP?.disconnect()
        await oldGateway?.disconnect()
        guard generation == localGeneration else { return makeSnapshot() }
        transition(to: .requestingGatewayState)
        return await runJoin(generation: localGeneration)
    }

    /// Immediately closes admission and advances the generation before any
    /// asynchronous teardown begins. Late callbacks therefore cannot resurrect
    /// state or enqueue media after this method returns.
    public func stopNow() {
        let teardown = invalidateAndDetach(clearTarget: true)
        transition(to: .idle)
        Task {
            await teardown.udp?.disconnect()
            await teardown.gateway?.disconnect()
            if let guildID = teardown.guildID {
                await teardown.bridge.leaveVoice(guildID: guildID)
            }
        }
    }

    @discardableResult
    public func leave() async -> DiscordVoiceControllerSnapshot {
        let teardown = invalidateAndDetach(clearTarget: true)
        transition(to: .idle)
        await teardown.udp?.disconnect()
        await teardown.gateway?.disconnect()
        if let guildID = teardown.guildID {
            await teardown.bridge.leaveVoice(guildID: guildID)
        }
        return makeSnapshot()
    }

    @discardableResult
    public func disconnect() async -> DiscordVoiceControllerSnapshot {
        await leave()
    }

    public func shutdown() async {
        _ = await leave()
        let continuations = snapshotContinuations.values
        snapshotContinuations.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    @discardableResult
    public func setMicrophoneEnabled(_ enabled: Bool) -> DiscordVoiceControllerSnapshot {
        microphoneEnabled = enabled && acceptsFrames
        if phase == .readySpeaking, !microphoneEnabled {
            phase = .readyMuted
        }
        publish()
        return makeSnapshot()
    }

    @discardableResult
    public func setCameraEnabled(_ enabled: Bool) -> DiscordVoiceControllerSnapshot {
        cameraEnabled = enabled && acceptsFrames
        publish()
        return makeSnapshot()
    }

    @discardableResult
    public func setScreenShareEnabled(_ enabled: Bool) -> DiscordVoiceControllerSnapshot {
        screenShareEnabled = enabled && acceptsFrames
        publish()
        return makeSnapshot()
    }

    @discardableResult
    public func setSpeaking(_ speaking: Bool) -> DiscordVoiceControllerSnapshot {
        guard acceptsFrames else { return makeSnapshot() }
        phase = speaking && microphoneEnabled ? .readySpeaking : .readyMuted
        publish()
        return makeSnapshot()
    }

    public func admit(_ frame: DiscordVoiceOwnedMediaFrame) -> DiscordVoiceFrameAdmission {
        guard frame.generation == generation else { return .staleGeneration }
        guard acceptsFrames else { return .mediaNotReady }
        let admission: DiscordVoiceFrameAdmission
        switch frame {
        case .audio(let audio):
            guard microphoneEnabled else { return .captureDisabled }
            switch audioQueue.enqueue(audio) {
            case .accepted: admission = .accepted
            case .acceptedDroppingOldest: admission = .acceptedDroppingOldest
            }
        case .video(let video):
            let sourceEnabled = video.source == .camera ? cameraEnabled : screenShareEnabled
            guard sourceEnabled else { return .captureDisabled }
            switch videoQueue.enqueue(video) {
            case .accepted: admission = .accepted
            case .acceptedDroppingOldest: admission = .acceptedDroppingOldest
            }
        }
        publish()
        return admission
    }

    public func nextAudioFrame() -> DiscordVoiceOwnedAudioFrame? {
        let frame = audioQueue.dequeue()
        if frame != nil { publish() }
        return frame
    }

    public func nextVideoFrame() -> DiscordVoiceOwnedVideoFrame? {
        let frame = videoQueue.dequeue()
        if frame != nil { publish() }
        return frame
    }

    private func runJoin(generation localGeneration: UInt64) async -> DiscordVoiceControllerSnapshot {
        guard let target else { return makeSnapshot() }
        do {
            try await bridge.requestGatewayState(guildID: target.guildID, channelID: target.channelID)
        } catch {
            return await fail(.bridgeUnavailable, ifCurrent: localGeneration)
        }
        guard generation == localGeneration else { return makeSnapshot() }
        transition(to: .awaitingGatewayPair)

        let pairResult = await awaitPairWithTimeout()
        guard generation == localGeneration else { return makeSnapshot() }
        let pair: DiscordVoiceGatewayPair
        switch pairResult {
        case .pair(let value): pair = value
        case .timeout: return await fail(.credentialTimedOut, ifCurrent: localGeneration)
        case .failure: return await fail(.bridgeUnavailable, ifCurrent: localGeneration)
        case .cancelled: return makeSnapshot()
        }

        let gateway = factory.makeGatewayClient()
        let udp = factory.makeUDPDiscoverySession()
        gatewayClient = gateway
        udpSession = udp
        transition(to: .connectingVoiceGateway)

        let ready: DiscordVoiceGatewayTransportReady
        do {
            ready = try await gateway.connect(using: pair)
        } catch {
            return await fail(.gatewayUnavailable, ifCurrent: localGeneration)
        }
        guard generation == localGeneration else { return makeSnapshot() }
        transition(to: .negotiatingTransport)

        do {
            let endpoint = try await udp.discoverEndpoint(for: ready)
            guard generation == localGeneration else { return makeSnapshot() }
            try await gateway.selectTransport(endpoint)
        } catch {
            return await fail(.transportUnavailable, ifCurrent: localGeneration)
        }
        guard generation == localGeneration else { return makeSnapshot() }
        transition(to: .negotiatingDAVE)

        // The portable production boundary is deliberately fail-closed. Until a
        // concrete adapter attests that DAVE, AEAD, and Opus are all wired, this
        // actor remains at negotiation and reports mediaUnavailable.
        guard factory.mediaAdapterAvailability == .fullyWired else {
            return await fail(.mediaUnavailable, ifCurrent: localGeneration)
        }
        let capabilities: DiscordVoiceMediaCapabilities
        do {
            capabilities = try await gateway.negotiateDAVEAndMedia()
        } catch {
            return await fail(.mediaUnavailable, ifCurrent: localGeneration)
        }
        guard generation == localGeneration else { return makeSnapshot() }
        guard capabilities.isProductionReady else {
            return await fail(.mediaUnavailable, ifCurrent: localGeneration)
        }

        acceptsFrames = true
        // Capture permission is never inferred from a previous generation.
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        transition(to: .readyMuted)
        return makeSnapshot()
    }

    private func awaitPairWithTimeout() async -> DiscordVoicePairRaceResult {
        let bridge = self.bridge
        let sleeper = self.sleeper
        let timeout = configuration.credentialTimeout
        return await withTaskGroup(of: DiscordVoicePairRaceResult.self) { group in
            group.addTask {
                do { return .pair(try await bridge.awaitGatewayPair()) }
                catch is CancellationError { return .cancelled }
                catch { return .failure }
            }
            group.addTask {
                do {
                    try await sleeper(timeout)
                    return .timeout
                } catch {
                    return .cancelled
                }
            }
            while let result = await group.next() {
                if case .cancelled = result { continue }
                group.cancelAll()
                return result
            }
            return .cancelled
        }
    }

    private func beginGeneration(
        target: DiscordVoiceJoinTarget,
        initialPhase: DiscordVoiceControllerPhase
    ) -> UInt64 {
        generation &+= 1
        acceptsFrames = false
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        audioQueue.removeAll()
        videoQueue.removeAll()
        failure = nil
        self.target = target
        phase = initialPhase
        publish()
        return generation
    }

    private func invalidateAndDetach(clearTarget: Bool) -> (
        gateway: (any DiscordVoiceGatewaySessionClient)?,
        udp: (any DiscordVoiceUDPDiscoverySession)?,
        bridge: any DiscordVoiceGatewayPairBridge,
        guildID: String?
    ) {
        generation &+= 1
        acceptsFrames = false
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        audioQueue.removeAll()
        videoQueue.removeAll()
        failure = nil
        let guildID = target?.guildID
        let teardown = (gatewayClient, udpSession, bridge, guildID)
        gatewayClient = nil
        udpSession = nil
        if clearTarget { target = nil }
        return teardown
    }

    private func fail(
        _ failure: DiscordVoiceControllerFailure,
        ifCurrent localGeneration: UInt64
    ) async -> DiscordVoiceControllerSnapshot {
        guard generation == localGeneration else { return makeSnapshot() }
        let gateway = gatewayClient
        let udp = udpSession
        gatewayClient = nil
        udpSession = nil
        let guildID = target?.guildID
        acceptsFrames = false
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        audioQueue.removeAll()
        videoQueue.removeAll()
        self.failure = failure
        phase = .failed
        publish()
        await udp?.disconnect()
        await gateway?.disconnect()
        if let guildID {
            await bridge.leaveVoice(guildID: guildID)
        }
        return makeSnapshot()
    }

    private func transition(to phase: DiscordVoiceControllerPhase) {
        self.phase = phase
        publish()
    }

    private func makeSnapshot() -> DiscordVoiceControllerSnapshot {
        DiscordVoiceControllerSnapshot(
            phase: phase,
            generation: generation,
            microphoneEnabled: microphoneEnabled,
            cameraEnabled: cameraEnabled,
            screenShareEnabled: screenShareEnabled,
            queuedAudioFrames: audioQueue.count,
            queuedVideoFrames: videoQueue.count,
            droppedAudioFrames: audioQueue.droppedCount,
            droppedVideoFrames: videoQueue.droppedCount,
            failure: failure,
            mediaAdapterAvailable: factory.mediaAdapterAvailability == .fullyWired
        )
    }

    private func publish() {
        let snapshot = makeSnapshot()
        for continuation in snapshotContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeSnapshotContinuation(_ streamID: UInt64) {
        snapshotContinuations.removeValue(forKey: streamID)
    }
}
