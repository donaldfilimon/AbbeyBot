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
    /// The native stack is composed well enough to carry real audio on this
    /// machine — capture, receive, and the media plane are all present — but
    /// nothing is claimed to Discord. The advertised DAVE version stays 0.
    ///
    /// This case exists because the two-state version was self-locking: audio
    /// could not flow until availability opened, and availability was not
    /// supposed to open until live evidence existed, which required audio to
    /// flow. Separating "works locally" from "advertised on the wire" breaks
    /// that circle without overstating anything to Discord.
    case locallyComposed
    /// Everything above, PLUS the wire-facing claim: a nonzero DAVE version is
    /// advertised, which tells Discord this client can honor E2EE. Only set
    /// this when that is actually true.
    case fullyWired

    /// Whether audio may flow at all. Both composed states qualify; only
    /// `fullyWired` additionally advertises DAVE.
    public var permitsLocalMedia: Bool {
        self != .unavailable
    }
}

public protocol DiscordVoiceGatewayPairBridge: Sendable {
    func requestGatewayState(guildID: String, channelID: String) async throws
    func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair
    func leaveVoice(guildID: String) async
    /// See the protocol extension's default: main-gateway presence evidence
    /// gating the controller's full-reconnect fallback.
    func voicePresenceHeld() async -> Bool
}

public protocol DiscordVoiceGatewaySessionClient: Sendable {
    func connect(using pair: DiscordVoiceGatewayPair) async throws -> DiscordVoiceGatewayTransportReady
    func selectTransport(_ endpoint: DiscordVoiceDiscoveredEndpoint) async throws
    func negotiateDAVEAndMedia() async throws -> DiscordVoiceMediaCapabilities
    func disconnect() async
    /// Suspends until the session leaves service. `true` means the session
    /// terminated unexpectedly (terminal transport failure after its own
    /// buffered-resume budget is spent); `false` means an operator-requested
    /// disconnect. The default reports `false` immediately, which keeps the
    /// controller's full-reconnect fallback inert for clients that cannot
    /// distinguish termination causes.
    func awaitTermination() async -> Bool
    /// The user a received SSRC belongs to, learned from inbound Speaking
    /// (opcode 5), which carries `ssrc` and `user_id` together.
    ///
    /// DAVE's `unprotect` needs the sender's identity to select the right
    /// per-participant ratchet, and the media plane deliberately holds no
    /// SSRC→user map of its own. The lookup key is an SSRC read from an
    /// *unauthenticated* RTP header, which is safe precisely because a wrong
    /// answer cannot leak audio: the frame simply fails against that
    /// participant's ratchet and is counted as a drop.
    ///
    /// The default returns `nil`, so a client that never observes Speaking
    /// leaves receive fail-closed rather than guessing an identity.
    func senderID(forSSRC ssrc: UInt32) async -> UInt64?
}

extension DiscordVoiceGatewaySessionClient {
    public func awaitTermination() async -> Bool { false }
    public func senderID(forSSRC ssrc: UInt32) async -> UInt64? { nil }
}

extension DiscordVoiceGatewayPairBridge {
    /// Whether the main gateway's authoritative self VOICE_STATE_UPDATE
    /// evidence still shows the bot present in its voice channel. The
    /// full-reconnect fallback consults this before any rejoin so it never
    /// fights a Discord-initiated removal. The default reports `true`, which
    /// preserves the fallback for bridges that carry no presence evidence.
    public func voicePresenceHeld() async -> Bool { true }
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
    /// Suspends until one datagram arrives.
    ///
    /// **Must be cancellation-aware.** `DiscordVoiceReceiveLoop.stop()` drains
    /// its pump before returning and does not own the socket, so cancelling the
    /// pump task is the only thing that can unblock a receive in flight. An
    /// implementation that ignores cancellation turns the controller's ordered
    /// teardown into a hang. `DiscordVoiceUDPSession` satisfies this by
    /// resuming its receive waiter with `CancellationError`.
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
    /// Optional production receive loop bound to the same session-owned media
    /// plane and datagram transport as `gateway`. `nil` means this session
    /// receives nothing, which is what every portable factory does today.
    public let receiveLoop: (any DiscordVoiceReceiveLoopControlling)?
    /// Claim level for this exact session construction. A qualification-gated
    /// factory may be locally composed in general yet fully wired only for one
    /// content-free canary lease.
    public let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability?

    public init(
        gateway: any DiscordVoiceGatewaySessionClient,
        udp: any DiscordVoiceUDPDiscoverySession,
        captureLoop: (any DiscordVoiceCaptureLoopControlling)? = nil,
        receiveLoop: (any DiscordVoiceReceiveLoopControlling)? = nil,
        mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability? = nil
    ) {
        self.gateway = gateway
        self.udp = udp
        self.captureLoop = captureLoop
        self.receiveLoop = receiveLoop
        self.mediaAdapterAvailability = mediaAdapterAvailability
    }
}

public protocol DiscordVoiceSessionFactory: Sendable {
    var mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability { get }
    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession
    func makeSessionComponents() -> DiscordVoiceSessionComponents
    func makeSessionComponents(
        qualificationLease: DiscordVoiceQualificationLease?
    ) -> DiscordVoiceSessionComponents
}

public extension DiscordVoiceSessionFactory {
    func makeSessionComponents() -> DiscordVoiceSessionComponents {
        DiscordVoiceSessionComponents(
            gateway: makeGatewayClient(),
            udp: makeUDPDiscoverySession(),
            mediaAdapterAvailability: mediaAdapterAvailability
        )
    }

    func makeSessionComponents(
        qualificationLease: DiscordVoiceQualificationLease?
    ) -> DiscordVoiceSessionComponents {
        makeSessionComponents()
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
    /// The production receive loop could not start or terminated on its own
    /// (terminal transport failure, malformed RTP framing, or a playback
    /// failure). The session's signaling stays up; receive fails closed to
    /// inactive rather than silently half-running.
    case receiveUnavailable
}

/// Immutable and intentionally redacted. It contains no guild/channel/user IDs,
/// endpoint addresses, session IDs, tokens, encryption modes, or media bytes.
public struct DiscordVoiceControllerSnapshot: Equatable, Sendable, CustomStringConvertible {
    public let phase: DiscordVoiceControllerPhase
    public let generation: UInt64
    public let microphoneEnabled: Bool
    public let cameraEnabled: Bool
    public let screenShareEnabled: Bool
    /// Whether the session's receive loop is pumping. Always `false` for
    /// sessions with no receive loop installed.
    public let receiveActive: Bool
    public let queuedAudioFrames: Int
    public let queuedVideoFrames: Int
    public let droppedAudioFrames: UInt64
    public let droppedVideoFrames: UInt64
    public let failure: DiscordVoiceControllerFailure?
    /// The WIRE-FACING claim: a nonzero DAVE version is advertised to Discord.
    /// Deliberately keeps its original meaning so no existing reader silently
    /// starts reporting something stronger than before.
    public let mediaAdapterAvailable: Bool
    /// Audio may flow on this machine. True for both composed states, so it is
    /// true in cases where `mediaAdapterAvailable` is false — that combination
    /// is the whole point of the split and is not a contradiction.
    public let localMediaAvailable: Bool

    public var description: String {
        let failureDescription = failure?.rawValue ?? "none"
        return "DiscordVoiceControllerSnapshot(phase: \(phase.rawValue), generation: \(generation), microphone: \(microphoneEnabled), camera: \(cameraEnabled), screen: \(screenShareEnabled), receiveActive: \(receiveActive), audioQueued: \(queuedAudioFrames), videoQueued: \(queuedVideoFrames), failure: \(failureDescription), mediaAdapterAvailable: \(mediaAdapterAvailable), localMediaAvailable: \(localMediaAvailable))"
    }
}

public struct DiscordVoiceControllerConfiguration: Equatable, Sendable {
    public let credentialTimeout: Duration
    public let snapshotBufferLimit: Int
    public let audioQueueCapacity: Int
    public let videoQueueCapacity: Int
    /// Full-rejoin budget per operator-initiated join. Spent only by
    /// unexpected session terminations; zero disables the fallback so every
    /// unexpected termination fails closed immediately.
    public let maximumAutoReconnectAttempts: Int
    /// Production media is admitted only while an explicit consent epoch is
    /// installed. Tests and portable fixtures may leave this false.
    public let requiresConsentEpoch: Bool

    public init(
        credentialTimeout: Duration = .seconds(10),
        snapshotBufferLimit: Int = 32,
        audioQueueCapacity: Int = 64,
        videoQueueCapacity: Int = 4,
        maximumAutoReconnectAttempts: Int = 2,
        requiresConsentEpoch: Bool = false
    ) throws {
        guard credentialTimeout > .zero else {
            throw DiscordVoiceMediaContractError.invalidCredentialTimeout
        }
        guard (0...10).contains(maximumAutoReconnectAttempts) else {
            throw DiscordVoiceMediaContractError.invalidAutoReconnectAttempts(
                maximumAutoReconnectAttempts
            )
        }
        self.maximumAutoReconnectAttempts = maximumAutoReconnectAttempts
        self.requiresConsentEpoch = requiresConsentEpoch
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
    let receiveLoop: (any DiscordVoiceReceiveLoopControlling)?
    let bridge: any DiscordVoiceGatewayPairBridge
    let guildID: String?
    let requestLease: DiscordVoiceBridgeRequestLease?

    var needsTeardown: Bool {
        gateway != nil || udp != nil || captureLoop != nil || receiveLoop != nil
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
    private var receiveLoop: (any DiscordVoiceReceiveLoopControlling)?
    private var microphoneTransitionInFlight = false
    /// Desired microphone state recorded while a transition is suspended in
    /// `captureLoop.start`/`stop`. Reconciled by the in-flight transition
    /// instead of being dropped — see `setMicrophoneEnabled`.
    private var pendingMicrophoneDesiredState: Bool?
    /// The generation whose `captureLoop.start` is currently suspended, or
    /// `nil` when no start is in flight.
    private var captureStartInFlightGeneration: UInt64?
    /// Set when the capture loop reported a terminal failure during that
    /// suspended start, i.e. before `microphoneEnabled` could be set.
    private var captureTerminalDuringStart = false
    /// Receive mirrors the capture-start reentrancy mechanism rather than
    /// inventing a second one: `receiveLoop.start` is a cross-actor call and
    /// therefore suspends, so a terminal verdict can land before
    /// `receiveActive` is set. It is recorded here and reconciled by the
    /// resuming start. Receive has an operator toggle exactly like the
    /// microphone, so it uses the same pending-desired-state loop: a request
    /// landing mid-transition is recorded, not dropped.
    private var receiveTransitionInFlight = false
    private var pendingReceiveDesiredState: Bool?
    private var receiveStartInFlightGeneration: UInt64?
    private var receiveTerminalDuringStart = false
    private var receiveActive = false
    private var acceptsFrames = false
    private var nextTeardownID: UInt64 = 0
    private var teardownTasks: [UInt64: Task<Void, Never>] = [:]
    private var autoReconnectAttempts = 0
    private var sessionMonitorTask: Task<Void, Never>?

    private var microphoneEnabled = false
    private var cameraEnabled = false
    private var screenShareEnabled = false
    private var consentEpochHash: String?
    private var qualificationLease: DiscordVoiceQualificationLease?
    private var qualificationCapabilities = Set<LiveMediaCapability>()
    private var sessionMediaAvailability: DiscordVoiceMediaAdapterAvailability
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
        self.sessionMediaAvailability = factory.mediaAdapterAvailability
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
        await join(guildID: guildID, channelID: channelID, qualificationLease: nil)
    }

    /// Canary-only join. The lease is content-free and is accepted only for
    /// the exact guild digest approved by the qualification coordinator. It is
    /// consumed by this connection construction and is never inherited by a
    /// reconnect or replacement.
    @discardableResult
    public func join(
        guildID: String,
        channelID: String,
        qualificationLease lease: DiscordVoiceQualificationLease?
    ) async -> DiscordVoiceControllerSnapshot {
        // Register teardown before beginning the replacement. A stopNow task or
        // another replacement may already own older resources, and every such
        // task must finish before a new main-Gateway request is allowed.
        let prior = invalidateAndDetach(clearTarget: true)
        transition(to: .idle)
        enqueueTeardown(prior)
        if let lease {
            guard lease.admit(guildID: guildID) else {
                return await fail(.mediaUnavailable, ifCurrent: generation)
            }
            qualificationLease = lease
            consentEpochHash = lease.consentEpochHash
            qualificationCapabilities = lease.capabilities
        }
        // A fresh operator-initiated join refills the full-reconnect budget;
        // reconnect() deliberately does not.
        autoReconnectAttempts = 0
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
        consentEpochHash = nil
        let teardown = invalidateAndDetach(clearTarget: true)
        transition(to: .idle)
        enqueueTeardown(teardown)
    }

    @discardableResult
    public func leave() async -> DiscordVoiceControllerSnapshot {
        consentEpochHash = nil
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
    ///
    /// `captureLoop.start` suspends, so this actor is reentrant across it and
    /// anything that happens in that window must be *recorded and reconciled*,
    /// never dropped. One mechanism covers the three ways that bites:
    ///
    /// * a mute arriving mid-start is stored in
    ///   `pendingMicrophoneDesiredState` and re-applied by the reconcile loop
    ///   below, so a privacy action can never appear to succeed while capture
    ///   actually begins (last request wins);
    /// * a terminal verdict arriving mid-start is stored in
    ///   `captureTerminalDuringStart` and turned into the fail-closed result,
    ///   so an already-failed loop is never published as an enabled
    ///   microphone;
    /// * a start that provably succeeds clears a `.captureUnavailable` left by
    ///   an earlier failed start, so a recovered session never reports an
    ///   enabled microphone and a capture failure at the same time.
    /// Starts or stops decrypting and playing other members' audio.
    ///
    /// Off by default and never implied by joining a channel: receiving means
    /// decrypting other people's speech, so it is an explicit operator action,
    /// the same posture the microphone has. A failure to start fails closed —
    /// `receiveActive` stays false and the failure is operator-visible — rather
    /// than leaving the session in a state that looks like it is listening.
    @discardableResult
    public func setReceiveEnabled(_ enabled: Bool) async -> DiscordVoiceControllerSnapshot {
        if enabled, !permitsQualifiedCapability(.audioReceive) {
            failure = .receiveUnavailable
            publish()
            return makeSnapshot()
        }
        // Same reconcile loop as the microphone, for the same reason: both
        // start/stop steps suspend, so a request arriving during one must be
        // recorded rather than dropped. Turning receive OFF is a privacy
        // action; losing it would leave the bot decrypting audio after the
        // operator asked it to stop.
        guard !receiveTransitionInFlight else {
            pendingReceiveDesiredState = enabled
            return makeSnapshot()
        }
        receiveTransitionInFlight = true
        defer {
            receiveTransitionInFlight = false
            pendingReceiveDesiredState = nil
        }

        var desired = enabled
        while true {
            pendingReceiveDesiredState = nil
            await applyReceiveDesiredState(desired)
            guard let pending = pendingReceiveDesiredState else { break }
            pendingReceiveDesiredState = nil
            desired = pending
        }
        return makeSnapshot()
    }

    /// One reconciliation step toward `enabled`.
    private func applyReceiveDesiredState(_ enabled: Bool) async {
        guard let receiveLoop else {
            // No receive loop was composed for this session (no playback sink,
            // or a portable build). Refuse rather than report success.
            if enabled { failure = .receiveUnavailable }
            return
        }
        guard acceptsFrames else {
            if enabled { failure = .receiveUnavailable }
            return
        }
        if enabled == receiveActive { return }

        let localGeneration = generation
        if enabled {
            guard await startReceiveLoop(receiveLoop, generation: localGeneration) else {
                return
            }
        } else {
            // Clear the flag BEFORE the suspending stop, so nothing can read an
            // active receive after the operator has asked for silence — the
            // same ordering the mute path uses.
            receiveActive = false
            // Ordered teardown: the loop drains before this returns, so no
            // packet can race a later media reset.
            await receiveLoop.stop()
            guard generation == localGeneration else { return }
            // A clean operator stop is not a failure.
            if failure == .receiveUnavailable { failure = nil }
        }
        publish()
    }

    @discardableResult
    public func setMicrophoneEnabled(_ enabled: Bool) async -> DiscordVoiceControllerSnapshot {
        if enabled, !permitsQualifiedCapability(.audioSend) {
            failure = .captureUnavailable
            publish()
            return makeSnapshot()
        }
        guard !microphoneTransitionInFlight else {
            // Record rather than drop: the in-flight transition reconciles
            // this before it returns.
            pendingMicrophoneDesiredState = enabled
            return makeSnapshot()
        }
        microphoneTransitionInFlight = true
        defer {
            microphoneTransitionInFlight = false
            pendingMicrophoneDesiredState = nil
        }

        var desired = enabled
        while true {
            pendingMicrophoneDesiredState = nil
            await applyMicrophoneDesiredState(desired)
            // A request that landed while the step above was suspended wins.
            // Bounded: each concurrent caller contributes at most one extra
            // iteration, and a step that cannot suspend cannot enqueue one.
            guard let pending = pendingMicrophoneDesiredState else { break }
            pendingMicrophoneDesiredState = nil
            desired = pending
        }
        return makeSnapshot()
    }

    /// One reconciliation step toward `enabled`. Every suspension point is
    /// followed by a generation re-check; the start path additionally consults
    /// the terminal verdict that may have been recorded while it was
    /// suspended.
    private func applyMicrophoneDesiredState(_ enabled: Bool) async {
        let localGeneration = generation
        let target = enabled && acceptsFrames
        if target, !microphoneEnabled, let captureLoop {
            captureStartInFlightGeneration = localGeneration
            captureTerminalDuringStart = false
            do {
                try await captureLoop.start(generation: localGeneration)
            } catch {
                captureStartInFlightGeneration = nil
                captureTerminalDuringStart = false
                guard generation == localGeneration else { return }
                microphoneEnabled = false
                failure = .captureUnavailable
                publishUnlessSuperseded()
                return
            }
            // INVARIANT: from here to `microphoneEnabled = target` there must
            // be no suspension point on the enabling path. Clearing the
            // in-flight marker stops the terminal handler from recording, and
            // `microphoneEnabled` is not yet true, so a terminal landing in
            // between would be neither recorded nor acted on — reintroducing
            // exactly the bug this branch fixes. The two guards below are
            // synchronous, and the `!target` stop branch cannot be taken when
            // `target` is true.
            let terminalRacedStart = captureTerminalDuringStart
            captureStartInFlightGeneration = nil
            captureTerminalDuringStart = false
            guard generation == localGeneration, acceptsFrames else {
                // Superseded while capture was starting; teardown of the
                // detached session owns the loop, but stop here too so a
                // late-started source never outlives its generation.
                await captureLoop.stop()
                return
            }
            guard !terminalRacedStart else {
                // The loop already failed closed (an already-finished stream,
                // or a first send that failed immediately) before this start
                // returned. Honor that verdict rather than publishing an
                // enabled microphone that can never send a frame.
                microphoneEnabled = false
                failure = .captureUnavailable
                if phase == .readySpeaking {
                    phase = .readyMuted
                }
                publishUnlessSuperseded()
                await captureLoop.stop()
                return
            }
            if failure == .captureUnavailable {
                // The documented retry succeeded — clear the stale capture
                // failure so recovery is visible.
                failure = nil
            }
        }
        if !target, microphoneEnabled, let captureLoop {
            // Close frame admission BEFORE the device stop suspends. `admit`
            // gates on `microphoneEnabled` and publishes on its own, so an
            // accepted mute must not leave a window in which another frame is
            // admitted — or an enabled-microphone snapshot published — while
            // capture winds down. Together with the suppressed transient
            // publish above, this leaves no observable moment in which the
            // microphone reads enabled after a mute has been accepted.
            microphoneEnabled = false
            await captureLoop.stop()
            guard generation == localGeneration else { return }
        }
        microphoneEnabled = target
        if phase == .readySpeaking, !microphoneEnabled {
            phase = .readyMuted
        }
        publishUnlessSuperseded()
    }

    /// Suppresses a transient publish when a newer microphone request is
    /// already pending: consumers must never observe an enabled microphone
    /// between a mute being accepted and that mute being applied. The
    /// reconcile loop only exits with no request pending, so the settled state
    /// is always published.
    private func publishUnlessSuperseded() {
        guard pendingMicrophoneDesiredState == nil else { return }
        publish()
    }

    @discardableResult
    public func setCameraEnabled(_ enabled: Bool) -> DiscordVoiceControllerSnapshot {
        cameraEnabled = enabled && acceptsFrames && permitsQualifiedCapability(.cameraSend)
        publish()
        return makeSnapshot()
    }

    @discardableResult
    public func setScreenShareEnabled(_ enabled: Bool) -> DiscordVoiceControllerSnapshot {
        screenShareEnabled = enabled && acceptsFrames && permitsQualifiedCapability(.screenSend)
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

    /// Opens the runtime gate after the separate qualification coordinator has
    /// established unanimous consent for the exact current participant set.
    func installConsentEpoch(
        hash: String,
        capabilities: Set<LiveMediaCapability> = Set(LiveMediaCapability.allCases)
    ) throws -> DiscordVoiceControllerSnapshot {
        guard hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else {
            throw DiscordVoiceMediaContractError.invalidConsentEpoch
        }
        guard !capabilities.isEmpty else {
            throw DiscordVoiceMediaContractError.invalidConsentEpoch
        }
        consentEpochHash = hash
        qualificationCapabilities = capabilities
        failure = nil
        publish()
        return makeSnapshot()
    }

    /// Immediate privacy stop for participant, manager, connection, consent,
    /// interruption, background, or operator kill events.
    public func closeConsentEpoch() async -> DiscordVoiceControllerSnapshot {
        consentEpochHash = nil
        qualificationCapabilities.removeAll(keepingCapacity: false)
        cameraEnabled = false
        screenShareEnabled = false
        audioQueue.removeAll()
        videoQueue.removeAll()
        _ = await setMicrophoneEnabled(false)
        _ = await setReceiveEnabled(false)
        publish()
        return makeSnapshot()
    }

    private func permitsQualifiedCapability(_ capability: LiveMediaCapability) -> Bool {
        !configuration.requiresConsentEpoch
            || (consentEpochHash != nil && qualificationCapabilities.contains(capability))
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

        let components = factory.makeSessionComponents(qualificationLease: qualificationLease)
        sessionMediaAvailability = components.mediaAdapterAvailability
            ?? factory.mediaAdapterAvailability
        let gateway = components.gateway
        let udp = components.udp
        gatewayClient = gateway
        udpSession = udp
        captureLoop = components.captureLoop
        receiveLoop = components.receiveLoop
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
        guard sessionMediaAvailability.permitsLocalMedia,
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

        if let receiveLoop = components.receiveLoop {
            await receiveLoop.setTerminalHandler { [weak self] in
                await self?.handleReceiveLoopTerminal(generation: localGeneration)
            }
            guard generation == localGeneration else { return makeSnapshot() }
            // Deliberately NOT started here. Receiving decrypts other members'
            // speech, so joining a channel must not silently begin doing it —
            // receive is operator-gated and off by default, exactly like the
            // microphone below. `setReceiveEnabled(true)` is the only way in.
        }

        acceptsFrames = true
        // Neither capture nor receive is ever inferred from a previous
        // generation: both are privacy actions the operator must take again.
        receiveActive = false
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        transition(to: .readyMuted)
        // Started strictly AFTER the ready transition, with no suspension
        // point between: a termination verdict that is already pending can
        // therefore only be acted on once this join has fully returned, and
        // can never be overwritten by this method's own tail. (Starting the
        // monitor earlier let an interleaved `fail()` be stomped back to
        // `.readyMuted` — caught by the budget-exhaustion test.)
        startSessionMonitor(gateway: gateway, generation: localGeneration)
        return makeSnapshot()
    }

    /// Invoked by the capture loop when it fails closed on its own (send
    /// failure, malformed framing, unexpected capture end). The microphone
    /// drops to disabled and the failure is operator-visible; the established
    /// signaling session is left up.
    /// A terminal event can beat the controller's own `captureLoop.start`
    /// continuation — the source may hand back an already-finished stream, or
    /// the first send may fail immediately. `microphoneEnabled` is still false
    /// at that point, so the event is recorded for the resuming start instead
    /// of being discarded; discarding it let `setMicrophoneEnabled` go on to
    /// publish an enabled microphone over an already-failed loop.
    private func handleCaptureLoopTerminal(generation localGeneration: UInt64) {
        switch terminalDisposition(
            generation: localGeneration,
            laneIsActive: microphoneEnabled,
            startInFlightGeneration: captureStartInFlightGeneration
        ) {
        case .ignore:
            return
        case .recordForResumingStart:
            captureTerminalDuringStart = true
            return
        case .settle:
            break
        }
        microphoneEnabled = false
        failure = .captureUnavailable
        if phase == .readySpeaking {
            phase = .readyMuted
        }
        publish()
    }

    /// Starts the session's receive loop for `localGeneration`.
    ///
    /// Called only from `applyReceiveDesiredState` — NEVER from `join()`.
    /// Receiving decrypts other members' speech, so it starts only when the
    /// operator asks; a session that merely joined must stay silent.
    /// `receiveLoop.start` is a cross-actor call and therefore
    /// suspends, so the same two reentrancy hazards the capture path fixed apply
    /// here and are handled by the same mechanism:
    ///
    /// * superseded while starting — stop the loop so a late-started pump never
    ///   outlives its generation, and let the replacement own state;
    /// * a terminal verdict landing mid-start — recorded in
    ///   `receiveTerminalDuringStart` and honored here, rather than publishing
    ///   an active receive over an already-failed loop.
    ///
    /// A receive failure never fails the join: signaling stays up and the
    /// failure is operator-visible, exactly as a capture failure is.
    ///
    /// Returns `false` when this generation was superseded and the caller must
    /// abandon the join.
    private func startReceiveLoop(
        _ receiveLoop: any DiscordVoiceReceiveLoopControlling,
        generation localGeneration: UInt64
    ) async -> Bool {
        receiveStartInFlightGeneration = localGeneration
        receiveTerminalDuringStart = false
        do {
            try await receiveLoop.start(generation: localGeneration)
        } catch {
            receiveStartInFlightGeneration = nil
            receiveTerminalDuringStart = false
            guard generation == localGeneration else { return false }
            receiveActive = false
            failure = .receiveUnavailable
            return true
        }
        // INVARIANT: no suspension point between reading the recorded terminal
        // verdict and settling `receiveActive`. Clearing the in-flight marker
        // stops the terminal handler from recording, and `receiveActive` is not
        // yet true, so a verdict landing in between would be neither recorded
        // nor acted on.
        let terminalRacedStart = receiveTerminalDuringStart
        receiveStartInFlightGeneration = nil
        receiveTerminalDuringStart = false
        guard generation == localGeneration else {
            await receiveLoop.stop()
            return false
        }
        guard !terminalRacedStart else {
            receiveActive = false
            failure = .receiveUnavailable
            await receiveLoop.stop()
            return generation == localGeneration
        }
        receiveActive = true
        return true
    }

    /// Invoked by the receive loop when it fails closed on its own (terminal
    /// transport failure, malformed RTP framing, or a playback failure). Receive
    /// drops to inactive and the failure is operator-visible; the established
    /// signaling session is left up.
    private func handleReceiveLoopTerminal(generation localGeneration: UInt64) {
        switch terminalDisposition(
            generation: localGeneration,
            laneIsActive: receiveActive,
            startInFlightGeneration: receiveStartInFlightGeneration
        ) {
        case .ignore:
            return
        case .recordForResumingStart:
            receiveTerminalDuringStart = true
            return
        case .settle:
            break
        }
        receiveActive = false
        failure = .receiveUnavailable
        publishUnlessSuperseded()
    }

    /// What a lane must do with a terminal event that just arrived.
    private enum TerminalDisposition {
        /// A superseded generation, or a lane that is neither active nor
        /// starting. Nothing to record, nothing to settle.
        case ignore
        /// The lane has not finished starting, so settling now would be
        /// overwritten by the start that is still in flight. The caller records
        /// the verdict in its own `…TerminalDuringStart` flag and the resuming
        /// start honors it.
        case recordForResumingStart
        /// The lane is live: fail it closed and publish.
        case settle
    }

    /// The half of terminal handling that capture and receive genuinely share:
    /// deciding whether a terminal event can be acted on yet.
    ///
    /// This exists to stop a third lane from re-deriving it. Receive's handler
    /// was written by copying capture's by eye, and that copy-by-eye habit is
    /// what reintroduced two already-fixed bugs in the video send path on
    /// 2026-08-20. The subtle part is the middle case: a terminal event can beat
    /// the controller's own `start` continuation — a source may hand back an
    /// already-finished stream, or a first send may fail immediately — and at
    /// that moment the lane still reads inactive. Discarding the event there let
    /// the resuming start publish an enabled lane over an already-failed loop.
    ///
    /// Deliberately synchronous and non-mutating: a suspension point here would
    /// reopen the exact race `…TerminalDuringStart` exists to close, and leaving
    /// the mutation at the call sites keeps each lane's state changes visible
    /// where they happen rather than hidden behind this helper.
    private func terminalDisposition(
        generation localGeneration: UInt64,
        laneIsActive: Bool,
        startInFlightGeneration: UInt64?
    ) -> TerminalDisposition {
        guard generation == localGeneration else { return .ignore }
        guard laneIsActive else {
            return startInFlightGeneration == localGeneration
                ? .recordForResumingStart
                : .ignore
        }
        return .settle
    }

    /// Watches the live gateway session and drives the bounded full-reconnect
    /// fallback. Kick/move policy: before any rejoin, `sessionDidTerminate`
    /// consults the pair bridge's main-gateway presence evidence
    /// (`voicePresenceHeld()`). A Discord-authoritative removal — the bot's
    /// own null-channel VOICE_STATE_UPDATE — reads as presence lost and the
    /// fallback fails closed instead of rejoining, so it never fights a
    /// server-initiated removal. (Nothing external mutates the controller's
    /// `target`/`generation`; the presence gate, not any bridge-driven
    /// teardown, is what makes kicks safe.) Replaced monitors retire inertly
    /// through the generation and target guards once their session's
    /// teardown resolves.
    private func startSessionMonitor(
        gateway: any DiscordVoiceGatewaySessionClient,
        generation localGeneration: UInt64
    ) {
        sessionMonitorTask = Task { [weak self] in
            let unexpected = await gateway.awaitTermination()
            await self?.sessionDidTerminate(
                unexpected: unexpected,
                generation: localGeneration
            )
        }
    }

    private func sessionDidTerminate(
        unexpected: Bool,
        generation localGeneration: UInt64
    ) async {
        guard generation == localGeneration, unexpected, target != nil else { return }
        guard autoReconnectAttempts < configuration.maximumAutoReconnectAttempts else {
            _ = await fail(.gatewayUnavailable, ifCurrent: localGeneration)
            return
        }
        autoReconnectAttempts += 1
        let attempt = autoReconnectAttempts
        // Deterministic bounded delay (1s, 2s, 4s, capped at 8s). A single
        // client needs no jitter; the budget cap prevents rejoin loops.
        try? await sleeper(.seconds(min(8, 1 << (attempt - 1))))
        guard generation == localGeneration, target != nil else { return }
        // Kick/move gate: if the main gateway no longer shows the bot in its
        // channel, this termination was a Discord-initiated removal — never
        // rejoin over the server's decision; surface it as a failure instead.
        guard await bridge.voicePresenceHeld() else {
            _ = await fail(.gatewayUnavailable, ifCurrent: localGeneration)
            return
        }
        guard generation == localGeneration, target != nil else { return }
        _ = await reconnect()
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
        receiveActive = false
        audioQueue.removeAll()
        videoQueue.removeAll()
        failure = nil
        self.target = target
        phase = initialPhase
        publish()
        return generation
    }

    private func invalidateAndDetach(clearTarget: Bool) -> DiscordVoiceDetachedSession {
        // The monitor holds no teardown-bearing resources — it self-retires
        // when its session's teardown resolves the termination signal, and
        // the generation guard below makes any late verdict inert. Cancel is
        // ownership hygiene, keeping the generation-scoped-task invariant
        // visible rather than load-bearing.
        sessionMonitorTask?.cancel()
        sessionMonitorTask = nil
        // A consent epoch is bound to exactly one Voice Gateway/UDP
        // connection. Joining or reconnecting replaces that connection, so
        // retaining the old epoch would let a newly negotiated session inherit
        // consent that was never granted to it. The operator must open and
        // install a fresh epoch after every replacement.
        consentEpochHash = nil
        qualificationLease = nil
        qualificationCapabilities.removeAll(keepingCapacity: false)
        sessionMediaAvailability = factory.mediaAdapterAvailability
        generation &+= 1
        acceptsFrames = false
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        receiveActive = false
        audioQueue.removeAll()
        videoQueue.removeAll()
        failure = nil
        let guildID = bridgeGuildID
        let teardown = DiscordVoiceDetachedSession(
            gateway: gatewayClient,
            udp: udpSession,
            captureLoop: captureLoop,
            receiveLoop: receiveLoop,
            bridge: bridge,
            guildID: guildID,
            requestLease: bridgeRequestLease
        )
        gatewayClient = nil
        udpSession = nil
        captureLoop = nil
        receiveLoop = nil
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
            await session.receiveLoop?.stop()
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
        let detachedReceiveLoop = receiveLoop
        gatewayClient = nil
        udpSession = nil
        captureLoop = nil
        receiveLoop = nil
        let guildID = bridgeGuildID
        let requestLease = bridgeRequestLease
        bridgeGuildID = nil
        bridgeRequestLease = nil
        acceptsFrames = false
        microphoneEnabled = false
        cameraEnabled = false
        screenShareEnabled = false
        receiveActive = false
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
                receiveLoop: detachedReceiveLoop,
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
            receiveActive: receiveActive,
            queuedAudioFrames: audioQueue.count,
            queuedVideoFrames: videoQueue.count,
            droppedAudioFrames: audioQueue.droppedCount,
            droppedVideoFrames: videoQueue.droppedCount,
            failure: failure,
            mediaAdapterAvailable: sessionMediaAvailability == .fullyWired,
            localMediaAvailable: sessionMediaAvailability.permitsLocalMedia
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
