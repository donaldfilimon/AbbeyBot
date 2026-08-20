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

/// Protected datagram access to the exact UDP socket used for Discord IP discovery.
/// Implementations retain socket ownership and never expose endpoints or packet contents
/// through diagnostics.
public protocol DiscordVoiceMediaDatagramTransport: Sendable {
    func sendProtectedPacket(_ bytes: [UInt8]) async throws
    func receiveProtectedPacket() async throws -> [UInt8]
    func disconnect() async
}

public struct DiscordVoiceSessionComponents: Sendable {
    public let gateway: any DiscordVoiceGatewaySessionClient
    public let udp: any DiscordVoiceUDPDiscoverySession
    /// Optional production capture loop bound to the same session-owned media
    /// plane as `gateway`. `nil` preserves the injected `admit()` /
    /// `nextAudioFrame()` path used by portable factories and tests.
    public let captureLoop: (any DiscordVoiceCaptureLoopControlling)?

    public init(
        gateway: any DiscordVoiceGatewaySessionClient,
        udp: any DiscordVoiceUDPDiscoverySession,
        captureLoop: (any DiscordVoiceCaptureLoopControlling)? = nil
    ) {
        self.gateway = gateway
        self.udp = udp
        self.captureLoop = captureLoop
    }
}

public protocol DiscordVoiceSessionFactory: Sendable {
    var mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability { get }
    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession
    func makeSessionComponents() -> DiscordVoiceSessionComponents
}

public extension DiscordVoiceSessionFactory {
    func makeSessionComponents() -> DiscordVoiceSessionComponents {
        DiscordVoiceSessionComponents(
            gateway: makeGatewayClient(),
            udp: makeUDPDiscoverySession()
        )
    }
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
    /// The production capture loop could not start or terminated on its own
    /// (permission, device loss, or a protected-send failure). The session's
    /// signaling stays up; the microphone fails closed to disabled.
    case captureUnavailable
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

/// Ownership record installed before the main-Gateway request can suspend.
/// Teardown awaits the same result and leaves exactly once only when Discord's
/// producer accepted the request.
private actor DiscordVoiceBridgeRequestLease {
    let guildID: String
    private let requestTask: Task<Bool, Never>

    init(
        bridge: any DiscordVoiceGatewayPairBridge,
        guildID: String,
        channelID: String
    ) {
        self.guildID = guildID
        self.requestTask = Task {
            do {
                try await bridge.requestGatewayState(guildID: guildID, channelID: channelID)
                return true
            } catch {
                return false
            }
        }
    }

    func wasAccepted() async -> Bool {
        await requestTask.value
    }
}

private struct DiscordVoiceDetachedSession: Sendable {
    let gateway: (any DiscordVoiceGatewaySessionClient)?
    let udp: (any DiscordVoiceUDPDiscoverySession)?
    let captureLoop: (any DiscordVoiceCaptureLoopControlling)?
    let bridge: any DiscordVoiceGatewayPairBridge
    let guildID: String?
    let requestLease: DiscordVoiceBridgeRequestLease?

    var needsTeardown: Bool {
        gateway != nil || udp != nil || captureLoop != nil
            || guildID != nil || requestLease != nil
    }
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
    private var bridgeGuildID: String?
    private var bridgeRequestLease: DiscordVoiceBridgeRequestLease?
    private var gatewayClient: (any DiscordVoiceGatewaySessionClient)?
    private var udpSession: (any DiscordVoiceUDPDiscoverySession)?
    private var captureLoop: (any DiscordVoiceCaptureLoopControlling)?
    private var microphoneTransitionInFlight = false
    private var acceptsFrames = false
    private var nextTeardownID: UInt64 = 0
    private var teardownTasks: [UInt64: Task<Void, Never>] = [:]

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
        // Register teardown before beginning the replacement. A stopNow task or
        // another replacement may already own older resources, and every such
        // task must finish before a new main-Gateway request is allowed.
        let prior = invalidateAndDetach(clearTarget: true)
        transition(to: .idle)
        enqueueTeardown(prior)
        let localGeneration = beginGeneration(
            target: DiscordVoiceJoinTarget(guildID: guildID, channelID: channelID),
            initialPhase: .requestingGatewayState
        )
        await drainPendingTeardowns()
        guard generation == localGeneration else { return makeSnapshot() }
        return await runJoin(generation: localGeneration)
    }

    @discardableResult
    public func reconnect() async -> DiscordVoiceControllerSnapshot {
        guard let target else { return makeSnapshot() }
        let prior = invalidateAndDetach(clearTarget: false)
        transition(to: .reconnecting)
        enqueueTeardown(prior)
        let localGeneration = beginGeneration(target: target, initialPhase: .reconnecting)
        await drainPendingTeardowns()
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
        enqueueTeardown(teardown)
    }

    @discardableResult
    public func leave() async -> DiscordVoiceControllerSnapshot {
        let teardown = invalidateAndDetach(clearTarget: true)
        transition(to: .idle)
        enqueueTeardown(teardown)
        await drainPendingTeardowns()
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

    /// Gates the production capture loop on the operator's mute state:
    /// enabling the microphone starts capture for the current established
    /// generation, disabling it stops capture at the device boundary (not
    /// merely at frame admission). A capture-loop start failure fails closed —
    /// the microphone stays disabled and `failure` reports
    /// `.captureUnavailable` — while signaling stays up.
    @discardableResult
    public func setMicrophoneEnabled(_ enabled: Bool) async -> DiscordVoiceControllerSnapshot {
        guard !microphoneTransitionInFlight else { return makeSnapshot() }
        microphoneTransitionInFlight = true
        defer { microphoneTransitionInFlight = false }

        let target = enabled && acceptsFrames
        if target, !microphoneEnabled, let captureLoop {
            let localGeneration = generation
            do {
                try await captureLoop.start(generation: localGeneration)
            } catch {
                guard generation == localGeneration else { return makeSnapshot() }
                microphoneEnabled = false
                failure = .captureUnavailable
                publish()
                return makeSnapshot()
            }
            guard generation == localGeneration, acceptsFrames else {
                // Superseded while capture was starting; teardown of the
                // detached session owns the loop, but stop here too so a
                // late-started source never outlives its generation.
                await captureLoop.stop()
                return makeSnapshot()
            }
        }
        if !target, microphoneEnabled, let captureLoop {
            await captureLoop.stop()
        }
        microphoneEnabled = target
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
        let requestLease = DiscordVoiceBridgeRequestLease(
            bridge: bridge,
            guildID: target.guildID,
            channelID: target.channelID
        )
        bridgeRequestLease = requestLease
        let requestAccepted = await requestLease.wasAccepted()
        guard generation == localGeneration else { return makeSnapshot() }
        bridgeRequestLease = nil
        guard requestAccepted else {
            return await fail(.bridgeUnavailable, ifCurrent: localGeneration)
        }
        bridgeGuildID = target.guildID
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

        let components = factory.makeSessionComponents()
        let gateway = components.gateway
        let udp = components.udp
        gatewayClient = gateway
        udpSession = udp
        captureLoop = components.captureLoop
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

        let capabilities: DiscordVoiceMediaCapabilities
        do {
            capabilities = try await gateway.negotiateDAVEAndMedia()
        } catch {
            return await fail(.mediaUnavailable, ifCurrent: localGeneration)
        }
        guard generation == localGeneration else { return makeSnapshot() }
        // Always complete the secure Gateway-to-media-plane bootstrap first,
        // then apply the product claim gate. This lets an unavailable factory
        // prove Phase 4 without presenting audio as shipped before Phase 5.
        guard factory.mediaAdapterAvailability == .fullyWired,
              capabilities.isProductionReady
        else {
            return await fail(.mediaUnavailable, ifCurrent: localGeneration)
        }

        if let captureLoop = components.captureLoop {
            await captureLoop.setTerminalHandler { [weak self] in
                await self?.handleCaptureLoopTerminal(generation: localGeneration)
            }
            guard generation == localGeneration else { return makeSnapshot() }
        }

        acceptsFrames = true
        // Capture permission is never inferred from a previous generation.
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        transition(to: .readyMuted)
        return makeSnapshot()
    }

    /// Invoked by the capture loop when it fails closed on its own (send
    /// failure, malformed framing, unexpected capture end). The microphone
    /// drops to disabled and the failure is operator-visible; the established
    /// signaling session is left up.
    private func handleCaptureLoopTerminal(generation localGeneration: UInt64) {
        guard generation == localGeneration, microphoneEnabled else { return }
        microphoneEnabled = false
        failure = .captureUnavailable
        if phase == .readySpeaking {
            phase = .readyMuted
        }
        publish()
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

    private func invalidateAndDetach(clearTarget: Bool) -> DiscordVoiceDetachedSession {
        generation &+= 1
        acceptsFrames = false
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        audioQueue.removeAll()
        videoQueue.removeAll()
        failure = nil
        let guildID = bridgeGuildID
        let teardown = DiscordVoiceDetachedSession(
            gateway: gatewayClient,
            udp: udpSession,
            captureLoop: captureLoop,
            bridge: bridge,
            guildID: guildID,
            requestLease: bridgeRequestLease
        )
        gatewayClient = nil
        udpSession = nil
        captureLoop = nil
        bridgeGuildID = nil
        bridgeRequestLease = nil
        if clearTarget { target = nil }
        return teardown
    }

    private func enqueueTeardown(_ session: DiscordVoiceDetachedSession) {
        guard session.needsTeardown else { return }
        nextTeardownID &+= 1
        let teardownID = nextTeardownID
        teardownTasks[teardownID] = Task {
            // Ordered teardown: capture stops first so no frame can race the
            // media reset, then gateway teardown resets the session-owned
            // media plane and its key-bearing state before the retained
            // discovery/media socket is allowed to close.
            await session.captureLoop?.stop()
            await session.gateway?.disconnect()
            await session.udp?.disconnect()
            if let requestLease = session.requestLease,
               await requestLease.wasAccepted()
            {
                await session.bridge.leaveVoice(guildID: requestLease.guildID)
            } else if let guildID = session.guildID {
                await session.bridge.leaveVoice(guildID: guildID)
            }
        }
    }

    private func drainPendingTeardowns() async {
        while !teardownTasks.isEmpty {
            let pending = teardownTasks
            for (teardownID, task) in pending {
                await task.value
                teardownTasks.removeValue(forKey: teardownID)
            }
        }
    }

    private func fail(
        _ failure: DiscordVoiceControllerFailure,
        ifCurrent localGeneration: UInt64
    ) async -> DiscordVoiceControllerSnapshot {
        guard generation == localGeneration else { return makeSnapshot() }
        let gateway = gatewayClient
        let udp = udpSession
        let detachedCaptureLoop = captureLoop
        gatewayClient = nil
        udpSession = nil
        captureLoop = nil
        let guildID = bridgeGuildID
        let requestLease = bridgeRequestLease
        bridgeGuildID = nil
        bridgeRequestLease = nil
        acceptsFrames = false
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        audioQueue.removeAll()
        videoQueue.removeAll()
        self.failure = failure
        phase = .failed
        publish()
        enqueueTeardown(
            DiscordVoiceDetachedSession(
                gateway: gateway,
                udp: udp,
                captureLoop: detachedCaptureLoop,
                bridge: bridge,
                guildID: guildID,
                requestLease: requestLease
            )
        )
        await drainPendingTeardowns()
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
