import AbbeyCore
import AbbeyMediaMacOS
import CoreGraphics
import Foundation
import Observation
#if canImport(AbbeyMediaNative)
import AbbeyMediaNative
#endif

struct MediaSessionDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let supportsInput: Bool
    let supportsOutput: Bool
    let isDefaultInput: Bool
    let isDefaultOutput: Bool
}

struct MediaSessionRuntimeSnapshot: Equatable, Sendable {
    let microphoneCapturing: Bool
    let cameraCapturing: Bool
    let screenCapturing: Bool
    let inputLevel: Double
    let outputLevel: Double

    static let stopped = Self(
        microphoneCapturing: false,
        cameraCapturing: false,
        screenCapturing: false,
        inputLevel: 0,
        outputLevel: 0
    )
}

/// App-facing copy of the already-redacted controller state. It intentionally
/// omits all guild, channel, endpoint, user, session, token, and mode values.
struct MediaSessionVoiceSnapshot: Equatable, Sendable {
    let phase: DiscordVoiceControllerPhase
    let generation: UInt64
    let failure: DiscordVoiceControllerFailure?
    /// The wire-facing claim: a nonzero DAVE version is advertised to Discord.
    let mediaAdapterAvailable: Bool
    /// Audio may flow on this machine. True in cases where
    /// `mediaAdapterAvailable` is false — that is the point of the split, not a
    /// contradiction.
    let localMediaAvailable: Bool
    /// Whether the bot is currently decrypting and playing other members' audio.
    let receiveActive: Bool

    init(_ snapshot: DiscordVoiceControllerSnapshot) {
        phase = snapshot.phase
        generation = snapshot.generation
        failure = snapshot.failure
        mediaAdapterAvailable = snapshot.mediaAdapterAvailable
        localMediaAvailable = snapshot.localMediaAvailable
        receiveActive = snapshot.receiveActive
    }

    static let idle = Self(
        phase: .idle,
        generation: 0,
        failure: nil,
        mediaAdapterAvailable: false,
        localMediaAvailable: false,
        receiveActive: false
    )

    private init(
        phase: DiscordVoiceControllerPhase,
        generation: UInt64,
        failure: DiscordVoiceControllerFailure?,
        mediaAdapterAvailable: Bool,
        localMediaAvailable: Bool,
        receiveActive: Bool
    ) {
        self.phase = phase
        self.generation = generation
        self.failure = failure
        self.mediaAdapterAvailable = mediaAdapterAvailable
        self.localMediaAvailable = localMediaAvailable
        self.receiveActive = receiveActive
    }
}

/// Redacted presence-only snapshot of the bot's gateway `VOICE_STATE_UPDATE`.
/// No guild, channel, or other identifier crosses into the app layer — only
/// whether Discord has confirmed the bot in a channel and the last confirmed
/// self-mute/self-deaf bits. These flags change what Discord and other members
/// observe and remain independent of any separately qualified media lane.
struct VoicePresenceSnapshot: Equatable, Sendable {
    let confirmedInChannel: Bool
    let selfMute: Bool
    let selfDeaf: Bool

    static let unconfirmed = Self(confirmedInChannel: false, selfMute: false, selfDeaf: false)
}

/// Thin port over the Discord gateway's presence-only voice-state update so the
/// mute/deafen toggle is hermetically testable without a live gateway.
protocol VoicePresencePort: Sendable {
    func currentPresence() async -> VoicePresenceSnapshot
    func setMuteState(selfMute: Bool, selfDeaf: Bool) async -> VoiceUpdateResult
}

/// Production adapter: forwards to `DiscordBridge`'s confirmed self voice state
/// and its presence-only mute/deafen update, without exposing guild/channel IDs.
struct DiscordBridgeVoicePresencePort: VoicePresencePort {
    let bridge: DiscordBridge

    func currentPresence() async -> VoicePresenceSnapshot {
        // A single actor-isolated read — never three separate hops that could
        // tear across a concurrent leave.
        let state = await bridge.voicePresenceState()
        return VoicePresenceSnapshot(
            confirmedInChannel: state.confirmedInChannel,
            selfMute: state.selfMute,
            selfDeaf: state.selfDeaf
        )
    }

    func setMuteState(selfMute: Bool, selfDeaf: Bool) async -> VoiceUpdateResult {
        await bridge.updateVoiceMuteState(selfMute: selfMute, selfDeaf: selfDeaf)
    }
}

/// Default port before any Discord bridge is wired (matches the construction-
/// is-passive contract other `MediaSessionModel` tests rely on): reports
/// unconfirmed presence and refuses mute/deafen sends rather than guessing.
private struct UnavailableVoicePresencePort: VoicePresencePort {
    func currentPresence() async -> VoicePresenceSnapshot { .unconfirmed }
    func setMuteState(selfMute: Bool, selfDeaf: Bool) async -> VoiceUpdateResult { .gatewayUnavailable }
}

protocol VoiceQualificationPort: Sendable {
    func participantSnapshot(guildID: String, channelID: String) async
        -> DiscordVoiceParticipantSnapshot
    func managerAuthorized(guildID: String, userID: String) async -> Bool
    func participantSnapshots(guildID: String, channelID: String) async
        -> AsyncStream<DiscordVoiceParticipantSnapshot>
}

extension VoiceQualificationPort {
    func participantSnapshots(guildID: String, channelID: String) async
        -> AsyncStream<DiscordVoiceParticipantSnapshot>
    {
        let snapshot = await participantSnapshot(guildID: guildID, channelID: channelID)
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }
}

private struct UnavailableVoiceQualificationPort: VoiceQualificationPort {
    func participantSnapshot(guildID: String, channelID: String) async
        -> DiscordVoiceParticipantSnapshot
    {
        .init(count: 0, participantDigests: [], isComplete: false)
    }
    func managerAuthorized(guildID: String, userID: String) async -> Bool { false }
}

private struct DiscordBridgeVoiceQualificationPort: VoiceQualificationPort {
    let bridge: DiscordBridge
    func participantSnapshot(guildID: String, channelID: String) async
        -> DiscordVoiceParticipantSnapshot
    {
        await bridge.voiceParticipantSnapshot(guildID: guildID, channelID: channelID)
    }
    func managerAuthorized(guildID: String, userID: String) async -> Bool {
        await bridge.currentManagerAuthorization(guildID: guildID, userID: userID)
    }
    func participantSnapshots(guildID: String, channelID: String) async
        -> AsyncStream<DiscordVoiceParticipantSnapshot>
    {
        await bridge.voiceParticipantSnapshots(guildID: guildID, channelID: channelID)
    }
}

protocol MediaSessionPlatform: Sendable {
    func isMediaDisabled() async -> Bool
    func authorizationStatus(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus
    func requestAuthorization(for kind: MediaPermissionKind) async throws -> MediaAuthorizationStatus
    func refreshAudioDevices() async -> [MediaSessionDevice]
    func selectInput(uid: String?) async throws -> String?
    func selectOutput(uid: String?) async throws -> String?
    func runtimeSnapshot() async -> MediaSessionRuntimeSnapshot
    /// Explicit opt-in LOCAL camera capture. Frames never leave this process;
    /// there is no Discord transmission path.
    func startCameraCapture() async throws -> UInt64
    /// Explicit opt-in LOCAL screen capture. Frames never leave this process;
    /// there is no Discord transmission path.
    func startScreenCapture() async throws -> UInt64
    /// Generation-scoped frames and terminal status changes for in-app preview only.
    func captureEvents() async -> AsyncStream<VideoCaptureEvent>
    func stopAllCapture() async
}

actor MacOSMediaSessionPlatform: MediaSessionPlatform {
    private let permissions: MediaPermissionController
    private let audioCatalog: AudioDeviceCatalog
    private let audio: AVAudioEngineAdapter
    private let video: VideoCaptureAdapter
    /// The capture bridge that hands the shared audio adapter's frames to the
    /// Discord capture loop, when one is installed. The kill switch must
    /// terminate it explicitly: stopping the adapter alone leaves the bridge's
    /// delivered stream open, so the loop would keep running against a dead
    /// device instead of failing closed.
    private let microphone: MicrophoneCaptureSource?

    init(
        permissions: MediaPermissionController = MediaPermissionController(),
        audioCatalog: AudioDeviceCatalog = AudioDeviceCatalog(),
        audio: AVAudioEngineAdapter = AVAudioEngineAdapter(),
        video: VideoCaptureAdapter = VideoCaptureAdapter(),
        microphone: MicrophoneCaptureSource? = nil
    ) {
        self.permissions = permissions
        self.audioCatalog = audioCatalog
        self.audio = audio
        self.video = video
        self.microphone = microphone
    }

    func isMediaDisabled() async -> Bool {
        await permissions.isMediaDisabled()
    }

    func authorizationStatus(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus {
        await permissions.authorizationStatus(for: kind)
    }

    func requestAuthorization(for kind: MediaPermissionKind) async throws -> MediaAuthorizationStatus {
        try await permissions.requestAuthorization(for: kind)
    }

    func refreshAudioDevices() async -> [MediaSessionDevice] {
        await audioCatalog.refresh().map {
            MediaSessionDevice(
                id: $0.uid,
                name: $0.name,
                supportsInput: $0.supportsInput,
                supportsOutput: $0.supportsOutput,
                isDefaultInput: $0.isDefaultInput,
                isDefaultOutput: $0.isDefaultOutput
            )
        }
    }

    func selectInput(uid: String?) async throws -> String? {
        let previous = await audioCatalog.selection()
        do {
            let input = try await audioCatalog.selectInput(uid: uid)
            let next = AudioDeviceSelection(input: input, output: previous.output)
            try await audio.setDeviceSelection(next)
            return input?.uid
        } catch {
            _ = try? await audioCatalog.selectInput(uid: previous.input?.uid)
            throw error
        }
    }

    func selectOutput(uid: String?) async throws -> String? {
        let previous = await audioCatalog.selection()
        do {
            let output = try await audioCatalog.selectOutput(uid: uid)
            let next = AudioDeviceSelection(input: previous.input, output: output)
            try await audio.setDeviceSelection(next)
            return output?.uid
        } catch {
            _ = try? await audioCatalog.selectOutput(uid: previous.output?.uid)
            throw error
        }
    }

    func runtimeSnapshot() async -> MediaSessionRuntimeSnapshot {
        let audioState = await audio.currentState()
        let videoStatus = await video.statusSnapshot()
        let microphoneCapturing = audioState == .capturing
        let videoCapturing = videoStatus.state == .capturing
        return MediaSessionRuntimeSnapshot(
            microphoneCapturing: microphoneCapturing,
            cameraCapturing: videoCapturing && videoStatus.selectedSource?.kind == .camera,
            screenCapturing: videoCapturing && videoStatus.selectedSource?.kind != .camera,
            // No meter stream is production-wired. Zero is an honest stopped/unavailable value.
            inputLevel: 0,
            outputLevel: 0
        )
    }

    func startCameraCapture() async throws -> UInt64 {
        try await startVideoCapture(permission: .camera)
    }

    func startScreenCapture() async throws -> UInt64 {
        try await startVideoCapture(permission: .screen)
    }

    func captureEvents() -> AsyncStream<VideoCaptureEvent> {
        video.captureEvents
    }

    func stopAllCapture() async {
        await video.killSwitch()
        await audio.stopNow()
        // `stopNow()` kills the device but leaves the bridge's delivered
        // capture stream open, and the adapter emits no runtime event for an
        // explicit stop. Finish the bridge here so the capture loop sees the
        // stream end, fails closed, and drops the controller's microphone to
        // disabled instead of reporting a live microphone on a dead device.
        // `MicrophoneCaptureSource.stopCapture()` is idempotent and leaves the
        // bridge reusable, so a later enable can start capture again.
        await microphone?.stopCapture()
    }

    /// Explicit opt-in LOCAL start path. It preflights authorization via the shared
    /// permission controller and fails closed before touching any device. It never
    /// prompts, never transmits, and starts nothing without an authorized TCC grant.
    private func startVideoCapture(permission kind: MediaPermissionKind) async throws -> UInt64 {
        let status = await permissions.authorizationStatus(for: kind)
        guard status == .authorized else {
            throw VideoCaptureError.permissionRequired(kind, status)
        }
        switch await video.statusSnapshot().state {
        case .capturing, .starting:
            throw VideoCaptureError.sourceRefreshRequiresStoppedCapture
        case .stopped:
            break
        case .interrupted, .sourceUnavailable, .failed:
            // Clear terminal residue so refresh/select see a stopped adapter.
            await video.stopCapture()
        }
        let sources = try await video.refreshSources()
        let source: VideoCaptureSourceSnapshot? = if kind == .camera {
            sources.first { $0.kind == .camera }
        } else {
            sources.first { $0.kind == .display } ?? sources.first { $0.kind == .window }
        }
        guard let source else { throw VideoCaptureError.sourceRequired }
        try await video.selectSource(id: source.id)
        return try await video.startCapture()
    }
}

enum MediaSessionCopy {
    static let daveUnavailable = "DAVE closed — ordinary sessions advertise version 0"
    static let captureUnavailable = "Media lanes closed until a fresh qualified consent epoch"
    static let sessionOnlySelection = "Device selections are session-only and are not persisted"
    static let localPreviewOnly =
        "Local preview only — frames stay on this Mac and are not transmitted; Discord video is not shipped"

    static func signaling(_ snapshot: MediaSessionVoiceSnapshot) -> String {
        switch snapshot.phase {
        case .idle: "Idle"
        case .requestingGatewayState: "Requesting main-gateway voice state"
        case .awaitingGatewayPair: "Awaiting one-shot voice credentials"
        case .connectingVoiceGateway: "Connecting Voice Gateway v8"
        case .negotiatingTransport, .negotiatingDAVE: "Voice Gateway signaling established"
        case .readyMuted, .readySpeaking: "Signaling ready"
        case .reconnecting: "Reconnecting signaling"
        case .failed: snapshot.failure == .mediaUnavailable ? "Signaling ended safely" : "Signaling failed"
        }
    }

    /// One literal phrase per `DiscordVoiceControllerPhase` case — the honest
    /// intermediate connection-lifecycle state, not a collapsed connected/
    /// disconnected binary. Complements `signaling`/`transport`, which describe
    /// what each phase means for the Gateway/UDP legs specifically.
    static func connectionPhase(_ snapshot: MediaSessionVoiceSnapshot) -> String {
        switch snapshot.phase {
        case .idle: "Not connected to voice"
        case .requestingGatewayState: "Requesting main-Gateway voice state (opcode 4 sent)"
        case .awaitingGatewayPair: "Awaiting Discord's Voice Gateway credentials"
        case .connectingVoiceGateway: "Connecting to Voice Gateway v8"
        case .negotiatingTransport: "Voice Gateway connected — negotiating UDP transport"
        case .negotiatingDAVE: "UDP transport selected — negotiating DAVE media"
        case .readyMuted: "Signaling ready — presence muted"
        case .readySpeaking: "Signaling ready — presence unmuted"
        case .reconnecting: "Reconnecting"
        case .failed:
            snapshot.failure == .mediaUnavailable
                ? "Stopped safely — DAVE media unavailable, no media sent"
                : "Failed — \(snapshot.failure?.rawValue ?? "unknown reason")"
        }
    }

    static func muteDeafen(confirmed: Bool, selfMute: Bool, selfDeaf: Bool) -> String {
        guard confirmed else { return "Not confirmed in a voice channel yet" }
        return "self-mute: \(selfMute ? "on" : "off"), self-deaf: \(selfDeaf ? "on" : "off") (Gateway presence state; independent of media-lane consent)"
    }

    static func transport(_ snapshot: MediaSessionVoiceSnapshot) -> String {
        switch snapshot.phase {
        case .negotiatingTransport: "Discovering persistent UDP route"
        case .negotiatingDAVE: "UDP route selected; media remains blocked"
        case .readyMuted, .readySpeaking: "Selected"
        case .failed where snapshot.failure == .mediaUnavailable:
            "Negotiated and closed before media"
        case .failed: "Unavailable"
        default: "Not selected"
        }
    }

    static func permission(_ status: MediaAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Not determined"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorized: "Authorized"
        case .unavailable: "Unavailable"
        }
    }
}

/// Main-actor, redacted state for Discord signaling and explicit local privacy diagnostics.
/// No active session, permission, source, device identifier, or frame is persisted.
@Observable
@MainActor
final class MediaSessionModel {
    private let controller: DiscordVoiceController
    private let platform: any MediaSessionPlatform
    private let presencePort: any VoicePresencePort
    private let qualificationPort: any VoiceQualificationPort
    private let qualificationCoordinator: LiveMediaQualificationCoordinator
    private let videoNegotiationProbe: DiscordVideoNegotiationProbe?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var captureEventTask: Task<Void, Never>?
    @ObservationIgnored private var participantObservationTask: Task<Void, Never>?
    @ObservationIgnored private var activeCaptureGeneration: UInt64?
    @ObservationIgnored private var activePreviewGeneration: UInt64?
    @ObservationIgnored private var localCaptureStartInFlight = false
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    @ObservationIgnored private var currentConsentAttestation = false

    private(set) var snapshot: MediaSessionVoiceSnapshot
    private(set) var permissions: [MediaPermissionKind: MediaAuthorizationStatus]
    private(set) var devices: [MediaSessionDevice] = []
    private(set) var selectedInputUID: String?
    private(set) var selectedOutputUID: String?
    private(set) var runtime = MediaSessionRuntimeSnapshot.stopped
    private(set) var mediaDisabled = false
    private(set) var isOperationInFlight = false
    private(set) var permissionInFlight: MediaPermissionKind?
    private(set) var operatorError: String?
    /// Latest LOCAL camera preview frame. Rendered in-app only; never transmitted.
    private(set) var cameraPreviewImage: CGImage?
    /// True once Discord's own self `VOICE_STATE_UPDATE` has confirmed the bot
    /// in a channel. Independent of `snapshot.phase`, which tracks the fuller
    /// signaling/transport/DAVE probe rather than raw gateway presence.
    private(set) var voicePresenceConfirmed = false
    /// Discord-confirmed self-mute/self-deaf presence bits. Presence only —
    /// these never substitute for the separate media-lane consent controls.
    private(set) var voiceSelfMute = false
    private(set) var voiceSelfDeaf = false
    private(set) var qualification = LiveMediaQualificationSnapshot(
        canaryEnabled: false,
        epoch: nil,
        lastCloseReason: nil,
        daveProtocolVersion: nil,
        codec: nil
    )
    private(set) var qualificationParticipantCount = 0
    private(set) var qualificationManagerAuthorized = false
    private(set) var videoNegotiationObservations: [DiscordVideoNegotiationObservation] = []

    var signalingLabel: String { MediaSessionCopy.signaling(snapshot) }
    var transportLabel: String { MediaSessionCopy.transport(snapshot) }
    /// One literal phrase per connection-lifecycle phase the controller actually
    /// models (idle → requesting → awaiting pair → connecting → negotiating
    /// transport → negotiating DAVE → ready → failed), never a collapsed
    /// connected/disconnected binary.
    var connectionPhaseLabel: String { MediaSessionCopy.connectionPhase(snapshot) }
    var muteDeafenLabel: String {
        MediaSessionCopy.muteDeafen(
            confirmed: voicePresenceConfirmed,
            selfMute: voiceSelfMute,
            selfDeaf: voiceSelfDeaf
        )
    }
    var daveLabel: String {
        if qualification.epoch != nil, snapshot.mediaAdapterAvailable {
            return "DAVE v\(qualification.daveProtocolVersion ?? 0) qualified canary"
        }
        return MediaSessionCopy.daveUnavailable
    }
    var captureLabel: String {
        qualification.epoch == nil
            ? MediaSessionCopy.captureUnavailable
            : "Consent epoch open; only explicitly selected lanes may start"
    }
    var localPreviewLabel: String { MediaSessionCopy.localPreviewOnly }
    var localCaptureActive: Bool {
        runtime.microphoneCapturing || runtime.cameraCapturing || runtime.screenCapturing
    }
    var localVideoCaptureActive: Bool {
        runtime.cameraCapturing || runtime.screenCapturing
    }

    init(
        controller: DiscordVoiceController,
        platform: any MediaSessionPlatform,
        presencePort: any VoicePresencePort = UnavailableVoicePresencePort(),
        qualificationPort: any VoiceQualificationPort = UnavailableVoiceQualificationPort(),
        videoNegotiationProbe: DiscordVideoNegotiationProbe? = nil,
        qualificationEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.controller = controller
        self.platform = platform
        self.presencePort = presencePort
        self.qualificationPort = qualificationPort
        self.videoNegotiationProbe = videoNegotiationProbe
        self.qualificationCoordinator = LiveMediaQualificationCoordinator(
            environment: qualificationEnvironment
        ) { reason in
            await platform.stopAllCapture()
            _ = await controller.closeConsentEpoch()
        }
        snapshot = .idle
        permissions = Dictionary(
            uniqueKeysWithValues: MediaPermissionKind.allCases.map { ($0, .notDetermined) }
        )
        observeController()
    }

    convenience init(discordBridge: DiscordBridge) {
        let configuration: DiscordVoiceControllerConfiguration
        do {
            configuration = try DiscordVoiceControllerConfiguration(requiresConsentEpoch: true)
        } catch {
            preconditionFailure("Static voice-controller configuration is invalid")
        }
        let controller: DiscordVoiceController
        let videoNegotiationProbe = DiscordVideoNegotiationProbe()
        // One shared audio engine boundary: the platform's device selection,
        // kill switch, and runtime snapshot operate on the same adapter whose
        // capture frames feed the Discord capture loop.
        let audio = AVAudioEngineAdapter()
        // The same bridge instance is handed to the session factory and to the
        // platform, so the kill switch terminates the very stream the capture
        // loop is pumping rather than only the adapter underneath it.
        let microphone = MicrophoneCaptureSource(adapter: audio)
        // Playback rides the SAME adapter as capture — one engine owns the
        // device, so the kill switch, deafen state, and runtime snapshot cover
        // both directions rather than only what we send.
        let speaker = SpeakerPlaybackSink(adapter: audio)
        do {
            let factory: any DiscordVoiceSessionFactory
#if canImport(AbbeyMediaNative)
            factory = DiscordVoiceNativeControlSessionFactory(
                captureSource: microphone,
                playbackSink: speaker,
                videoNegotiationProbe: videoNegotiationProbe
            )
#else
            factory = DiscordVoicePortableSessionFactory()
#endif
            controller = try DiscordVoiceController(
                bridge: DiscordVoiceBridgeAdapter(bridge: discordBridge),
                factory: factory,
                configuration: configuration
            )
        } catch {
            preconditionFailure("Static voice-controller queue configuration is invalid")
        }
        self.init(
            controller: controller,
            platform: MacOSMediaSessionPlatform(audio: audio, microphone: microphone),
            presencePort: DiscordBridgeVoicePresencePort(bridge: discordBridge),
            qualificationPort: DiscordBridgeVoiceQualificationPort(bridge: discordBridge),
            videoNegotiationProbe: videoNegotiationProbe
        )
    }

    /// Opens a fresh, exact-participant consent epoch and uses its content-free
    /// lease to construct one DAVE-capable canary connection. Manager authority
    /// is fetched live; a checkbox can attest consent but can never substitute
    /// for the current participant or permission facts.
    func openQualificationAndJoin(
        guildID: String,
        channelID: String,
        managerUserID: String,
        allCurrentParticipantsConsented: Bool,
        capabilities: Set<LiveMediaCapability>
    ) async {
        let guildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let managerUserID = managerUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guildID.isEmpty, !channelID.isEmpty, !managerUserID.isEmpty else {
            operatorError = "Guild, channel, and authorizing manager user IDs are required."
            return
        }
        guard !isOperationInFlight else { return }
        operationGeneration &+= 1
        let localGeneration = operationGeneration
        isOperationInFlight = true
        operatorError = nil
        currentConsentAttestation = allCurrentParticipantsConsented
        defer {
            if operationGeneration == localGeneration { isOperationInFlight = false }
        }
        let participants = await qualificationPort.participantSnapshot(
            guildID: guildID,
            channelID: channelID
        )
        guard operationGeneration == localGeneration else { return }
        let managerAuthorized = await qualificationPort.managerAuthorized(
            guildID: guildID,
            userID: managerUserID
        )
        guard operationGeneration == localGeneration else { return }
        qualificationParticipantCount = participants.count
        qualificationManagerAuthorized = managerAuthorized
        do {
            let epoch = try await qualificationCoordinator.open(
                guildID: guildID,
                guildAuthorizationClass: "discord-manager-authorized-canary",
                participantDigests: participants.participantDigests,
                participantSetComplete: participants.isComplete
                    && participants.count == participants.participantDigests.count,
                allCurrentParticipantsConsented: allCurrentParticipantsConsented,
                managerAuthorized: managerAuthorized,
                capabilities: capabilities,
                daveProtocolVersion: 1,
                codec: "H264"
            )
            guard operationGeneration == localGeneration else {
                await qualificationCoordinator.close(.connectionReplaced)
                return
            }
            let lease = try await qualificationCoordinator.qualificationLease()
            guard operationGeneration == localGeneration else {
                await qualificationCoordinator.close(.connectionReplaced)
                return
            }
            let joined = MediaSessionVoiceSnapshot(await controller.join(
                guildID: guildID,
                channelID: channelID,
                qualificationLease: lease
            ))
            guard operationGeneration == localGeneration else {
                _ = await controller.leave()
                await qualificationCoordinator.close(.connectionReplaced)
                return
            }
            snapshot = joined
            qualification = await qualificationCoordinator.snapshot()
            observeParticipants(
                guildID: guildID,
                channelID: channelID,
                epochHash: epoch.hash
            )
            videoNegotiationObservations = await videoNegotiationProbe?.observations() ?? []
            if snapshot.phase == .failed {
                stopParticipantObservation()
                await qualificationCoordinator.close(.connectionReplaced)
                qualification = await qualificationCoordinator.snapshot()
                operatorError = "The qualified media connection failed closed. No media was sent."
            }
        } catch {
            guard operationGeneration == localGeneration else { return }
            qualification = await qualificationCoordinator.snapshot()
            operatorError = Self.qualificationMessage(error)
        }
    }

    /// Rechecks live permission and participant facts for an open epoch. Any
    /// difference triggers the coordinator kill switch before the UI updates.
    func refreshQualification(
        guildID: String,
        channelID: String,
        managerUserID: String,
        allCurrentParticipantsConsented: Bool
    ) async {
        qualification = await qualificationCoordinator.snapshot()
        if qualification.epoch == nil { stopParticipantObservation() }
        videoNegotiationObservations = await videoNegotiationProbe?.observations() ?? []
        guard let epochHash = qualification.epoch?.hash else { return }
        currentConsentAttestation = allCurrentParticipantsConsented
        let participants = await qualificationPort.participantSnapshot(
            guildID: guildID,
            channelID: channelID
        )
        let managerAuthorized = await qualificationPort.managerAuthorized(
            guildID: guildID,
            userID: managerUserID
        )
        guard await qualificationCoordinator.snapshot().epoch?.hash == epochHash else { return }
        qualificationParticipantCount = participants.count
        qualificationManagerAuthorized = managerAuthorized
        do {
            try await qualificationCoordinator.revalidate(
                expectedEpochHash: epochHash,
                participantDigests: participants.participantDigests,
                participantSetComplete: participants.isComplete
                    && participants.count == participants.participantDigests.count,
                managerAuthorized: managerAuthorized,
                allCurrentParticipantsConsented: allCurrentParticipantsConsented
            )
        } catch {
            operatorError = Self.qualificationMessage(error)
        }
        qualification = await qualificationCoordinator.snapshot()
    }

    func closeQualification(_ reason: LiveMediaEpochCloseReason = .operatorStop) async {
        operationGeneration &+= 1
        let localGeneration = operationGeneration
        isOperationInFlight = true
        currentConsentAttestation = false
        stopParticipantObservation()
        await qualificationCoordinator.close(reason)
        guard operationGeneration == localGeneration else { return }
        qualification = await qualificationCoordinator.snapshot()
        runtime = await platform.runtimeSnapshot()
        snapshot = MediaSessionVoiceSnapshot(await controller.currentSnapshot())
        isOperationInFlight = false
    }

    func joinSignaling(guildID: String, channelID: String) async {
        if qualification.epoch != nil {
            stopParticipantObservation()
            await qualificationCoordinator.close(.connectionReplaced)
            qualification = await qualificationCoordinator.snapshot()
        }
        let guildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guildID.isEmpty, !channelID.isEmpty else {
            operatorError = "Guild ID and voice channel ID are required."
            return
        }
        guard !isOperationInFlight else { return }
        operationGeneration &+= 1
        let localGeneration = operationGeneration
        isOperationInFlight = true
        operatorError = nil
        let joinedSnapshot = MediaSessionVoiceSnapshot(
            await controller.join(guildID: guildID, channelID: channelID)
        )
        guard operationGeneration == localGeneration else { return }
        snapshot = joinedSnapshot
        isOperationInFlight = false
        if snapshot.phase == .failed, snapshot.failure == .mediaUnavailable {
            operatorError = "Signaling and UDP negotiation stopped safely because DAVE media is unavailable. No media was sent."
        }
        await refreshVoicePresence()
    }

    func leave() async {
        if qualification.epoch != nil {
            stopParticipantObservation()
            await qualificationCoordinator.close(.operatorStop)
            qualification = await qualificationCoordinator.snapshot()
        }
        operationGeneration &+= 1
        let localGeneration = operationGeneration
        isOperationInFlight = true
        invalidateLocalCapture()
        await platform.stopAllCapture()
        let leftSnapshot = MediaSessionVoiceSnapshot(await controller.leave())
        let stoppedRuntime = await platform.runtimeSnapshot()
        guard operationGeneration == localGeneration else { return }
        snapshot = leftSnapshot
        runtime = stoppedRuntime
        isOperationInFlight = false
        operatorError = nil
        await refreshVoicePresence()
    }

    func disconnect() async {
        if qualification.epoch != nil {
            stopParticipantObservation()
            await qualificationCoordinator.close(.connectionReplaced)
            qualification = await qualificationCoordinator.snapshot()
        }
        operationGeneration &+= 1
        let localGeneration = operationGeneration
        isOperationInFlight = true
        invalidateLocalCapture()
        await platform.stopAllCapture()
        let disconnectedSnapshot = MediaSessionVoiceSnapshot(await controller.disconnect())
        let stoppedRuntime = await platform.runtimeSnapshot()
        guard operationGeneration == localGeneration else { return }
        snapshot = disconnectedSnapshot
        runtime = stoppedRuntime
        isOperationInFlight = false
        operatorError = nil
        await refreshVoicePresence()
    }

    /// Awaited kill path: capture stops first, then generation invalidation and socket teardown.
    func stopAllMedia() async {
        if qualification.epoch != nil {
            stopParticipantObservation()
            await qualificationCoordinator.close(.emergencyStop)
            qualification = await qualificationCoordinator.snapshot()
        }
        operationGeneration &+= 1
        let localGeneration = operationGeneration
        isOperationInFlight = true
        invalidateLocalCapture()
        await platform.stopAllCapture()
        let stoppedSnapshot = MediaSessionVoiceSnapshot(await controller.leave())
        let stoppedRuntime = await platform.runtimeSnapshot()
        guard operationGeneration == localGeneration else { return }
        snapshot = stoppedSnapshot
        runtime = stoppedRuntime
        isOperationInFlight = false
        operatorError = nil
        await refreshVoicePresence()
    }

    func shutdown() async {
        operationGeneration &+= 1
        snapshotTask?.cancel()
        snapshotTask = nil
        captureEventTask?.cancel()
        captureEventTask = nil
        participantObservationTask?.cancel()
        participantObservationTask = nil
        invalidateLocalCapture()
        if qualification.epoch != nil {
            stopParticipantObservation()
            await qualificationCoordinator.close(.operatorStop)
        }
        await platform.stopAllCapture()
        await controller.shutdown()
        snapshot = MediaSessionVoiceSnapshot(await controller.currentSnapshot())
        runtime = await platform.runtimeSnapshot()
    }

    /// Status checks do not prompt. Requests happen only in `requestPermission`.
    func refreshPrivacyStatus() async {
        mediaDisabled = await platform.isMediaDisabled()
        for kind in MediaPermissionKind.allCases {
            permissions[kind] = mediaDisabled
                ? .unavailable
                : await platform.authorizationStatus(for: kind)
        }
        runtime = await platform.runtimeSnapshot()
    }

    /// Pulls Discord's confirmed self voice-state presence (channel
    /// confirmation plus self-mute/self-deaf). Independent of the
    /// signaling/transport/DAVE probe tracked by `snapshot`; call alongside the
    /// periodic Discord status refresh so this reflects Discord's own echo
    /// rather than an optimistic local guess.
    func refreshVoicePresence() async {
        let presence = await presencePort.currentPresence()
        voicePresenceConfirmed = presence.confirmedInChannel
        voiceSelfMute = presence.selfMute
        voiceSelfDeaf = presence.selfDeaf
    }

    /// Sends a presence-only self-mute/self-deaf `VOICE_STATE_UPDATE`. There is
    /// this changes what Discord and other members observe about the bot's
    /// presence and never authorizes, starts, or stops local media capture.
    /// `voiceSelfMute`/`voiceSelfDeaf` update only after Discord's echo is
    /// picked up by a following `refreshVoicePresence()`.
    func setMuteDeafen(selfMute: Bool, selfDeaf: Bool) async {
        guard !isOperationInFlight else { return }
        guard voicePresenceConfirmed else {
            operatorError = DiscordCopy.voiceMuteDeafenNotConfirmed
            return
        }
        switch await presencePort.setMuteState(selfMute: selfMute, selfDeaf: selfDeaf) {
        case .requested:
            operatorError = nil
        case .gatewayUnavailable:
            operatorError = DiscordCopy.voiceMuteDeafenGatewayUnavailable
        case .invalidIdentifiers:
            operatorError = DiscordCopy.voiceMuteDeafenNotConfirmed
        case .requestInProgress:
            operatorError = VoicePresence.requestInProgressMessage
        }
        await refreshVoicePresence()
    }

    /// Starts or stops decrypting and playing other members' audio.
    ///
    /// This is a privacy control, not a convenience: enabling it means the bot
    /// begins decrypting speech from everyone in the channel. It is off by
    /// default, is never implied by joining, and is not inherited across
    /// sessions — the controller clears it for every new generation.
    func setReceiveEnabled(_ enabled: Bool) async {
        guard !isOperationInFlight else { return }
        let updated = await controller.setReceiveEnabled(enabled)
        snapshot = MediaSessionVoiceSnapshot(updated)
        // Report the refusal rather than leaving a toggle that silently
        // sprang back: the operator asked for something and did not get it.
        if enabled, !updated.receiveActive {
            operatorError = DiscordCopy.voiceReceiveUnavailable
        } else {
            operatorError = nil
        }
    }

    func requestPermission(_ kind: MediaPermissionKind) async {
        mediaDisabled = await platform.isMediaDisabled()
        guard !mediaDisabled else {
            permissions[kind] = .unavailable
            operatorError = "Media is disabled by ABBEY_MEDIA_DISABLED=1. No permission request was made."
            return
        }
        guard permissionInFlight == nil else { return }
        permissionInFlight = kind
        defer { permissionInFlight = nil }
        do {
            permissions[kind] = try await platform.requestAuthorization(for: kind)
            operatorError = nil
        } catch {
            permissions[kind] = .unavailable
            operatorError = Self.safeMessage(for: error)
        }
    }

    func refreshDevices() async {
        mediaDisabled = await platform.isMediaDisabled()
        guard !mediaDisabled else {
            devices = []
            operatorError = "Media is disabled by ABBEY_MEDIA_DISABLED=1. No devices were enumerated."
            return
        }
        devices = await platform.refreshAudioDevices()
        operatorError = nil
    }

    /// Explicit opt-in LOCAL camera capture with in-app preview. Frames never leave
    /// this process; there is no Discord transmission path.
    func startCameraCapture() async {
        await startLocalCapture(preview: true) { platform in
            try await platform.startCameraCapture()
        }
    }

    /// Explicit opt-in LOCAL screen capture. Frames never leave this process;
    /// there is no Discord transmission path.
    func startScreenCapture() async {
        await startLocalCapture(preview: false) { platform in
            try await platform.startScreenCapture()
        }
    }

    /// Stops LOCAL capture only. Discord signaling state (if any) is untouched.
    func stopLocalCapture() async {
        operationGeneration &+= 1
        let localGeneration = operationGeneration
        isOperationInFlight = true
        invalidateLocalCapture()
        await platform.stopAllCapture()
        let stoppedRuntime = await platform.runtimeSnapshot()
        guard operationGeneration == localGeneration else { return }
        runtime = stoppedRuntime
        isOperationInFlight = false
        operatorError = nil
    }

    /// View-lifecycle privacy boundary. Preview-only capture must not outlive the
    /// Discord controls that disclose and stop it.
    func stopLocalCaptureWhenViewDisappears() async {
        guard localCaptureStartInFlight
                || activeCaptureGeneration != nil
                || localVideoCaptureActive
                || cameraPreviewImage != nil
        else {
            return
        }
        await stopLocalCapture()
    }

    func selectInput(uid: String?) async {
        await select { try await platform.selectInput(uid: uid) } assign: { selectedInputUID = $0 }
    }

    func selectOutput(uid: String?) async {
        await select { try await platform.selectOutput(uid: uid) } assign: { selectedOutputUID = $0 }
    }

    func permissionStatus(_ kind: MediaPermissionKind) -> MediaAuthorizationStatus {
        permissions[kind] ?? .unavailable
    }

    private func observeController() {
        let controller = controller
        snapshotTask = Task { [weak self] in
            let stream = await controller.snapshots()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                let incoming = MediaSessionVoiceSnapshot(snapshot)
                guard incoming.generation >= self.snapshot.generation else { continue }
                self.snapshot = incoming
            }
        }
    }

    private func observeParticipants(
        guildID: String,
        channelID: String,
        epochHash: String
    ) {
        participantObservationTask?.cancel()
        let qualificationPort = qualificationPort
        participantObservationTask = Task { [weak self] in
            let stream = await qualificationPort.participantSnapshots(
                guildID: guildID,
                channelID: channelID
            )
            for await participants in stream {
                guard !Task.isCancelled, let self else { return }
                let current = await self.qualificationCoordinator.snapshot()
                guard current.epoch?.hash == epochHash else { return }
                self.qualification = current
                self.qualificationParticipantCount = participants.count
                do {
                    try await self.qualificationCoordinator.revalidate(
                        expectedEpochHash: epochHash,
                        participantDigests: participants.participantDigests,
                        participantSetComplete: participants.isComplete
                            && participants.count == participants.participantDigests.count,
                        managerAuthorized: self.qualificationManagerAuthorized,
                        allCurrentParticipantsConsented: self.currentConsentAttestation
                    )
                } catch {
                    self.operatorError = Self.qualificationMessage(error)
                    self.qualification = await self.qualificationCoordinator.snapshot()
                    return
                }
            }
        }
    }

    private func stopParticipantObservation() {
        participantObservationTask?.cancel()
        participantObservationTask = nil
    }

    private func startLocalCapture(
        preview: Bool,
        _ operation: (any MediaSessionPlatform) async throws -> UInt64
    ) async {
        mediaDisabled = await platform.isMediaDisabled()
        guard !mediaDisabled else {
            operatorError = "Media is disabled by ABBEY_MEDIA_DISABLED=1. Local capture was not started."
            return
        }
        guard !isOperationInFlight else { return }
        guard activeCaptureGeneration == nil, !localVideoCaptureActive else {
            operatorError = "Local capture is already running. Stop it before starting another."
            return
        }
        operationGeneration &+= 1
        let localGeneration = operationGeneration
        isOperationInFlight = true
        localCaptureStartInFlight = true
        defer { localCaptureStartInFlight = false }
        invalidateLocalCapture()
        ensureCaptureEventTask()
        do {
            let captureGeneration = try await operation(platform)
            guard operationGeneration == localGeneration else { return }
            activeCaptureGeneration = captureGeneration
            activePreviewGeneration = preview ? captureGeneration : nil
            let startedRuntime = await platform.runtimeSnapshot()
            guard operationGeneration == localGeneration else { return }
            guard activeCaptureGeneration == captureGeneration else {
                // A terminal status arrived while the runtime snapshot was suspended.
                // Preserve the terminal handler's stopped state and cleared pixels.
                isOperationInFlight = false
                return
            }
            runtime = startedRuntime
            let expectedCaptureIsActive = preview
                ? startedRuntime.cameraCapturing
                : startedRuntime.screenCapturing
            guard expectedCaptureIsActive else {
                invalidateLocalCapture()
                operatorError = "Local capture ended before it became active. No media was sent."
                isOperationInFlight = false
                return
            }
            operatorError = nil
        } catch {
            let currentRuntime = await platform.runtimeSnapshot()
            guard operationGeneration == localGeneration else { return }
            runtime = currentRuntime
            operatorError = Self.safeMessage(for: error)
            invalidateLocalCapture()
        }
        isOperationInFlight = false
    }

    /// The adapter event stream is single-consumer. It carries capture generations
    /// with frames and lifecycle states, so queued work cannot cross a stop/restart.
    private func ensureCaptureEventTask() {
        guard captureEventTask == nil else { return }
        let platform = platform
        captureEventTask = Task { [weak self] in
            let events = await platform.captureEvents()
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.handleCaptureEvent(event)
            }
        }
    }

    private func handleCaptureEvent(_ event: VideoCaptureEvent) {
        switch event {
        case let .frame(generation, frame):
            guard generation == activePreviewGeneration else { return }
            cameraPreviewImage = VideoFramePreviewRenderer.makeCGImage(from: frame)
        case let .status(status):
            handleCaptureStatus(status)
        }
    }

    private func handleCaptureStatus(_ status: VideoCaptureStatusSnapshot) {
        switch status.state {
        case .stopped, .interrupted, .sourceUnavailable, .failed:
            guard let activeCaptureGeneration,
                  status.generation >= activeCaptureGeneration
            else { return }
            invalidateLocalCapture()
            runtime = MediaSessionRuntimeSnapshot(
                microphoneCapturing: runtime.microphoneCapturing,
                cameraCapturing: false,
                screenCapturing: false,
                inputLevel: runtime.inputLevel,
                outputLevel: runtime.outputLevel
            )
            switch status.state {
            case .failed:
                operatorError = "The local media operation failed. No media was sent."
            case .interrupted, .sourceUnavailable:
                operatorError = "Local capture stopped safely. No media was sent."
                if qualification.epoch != nil {
                    Task { await self.closeQualification(.sourceInterrupted) }
                }
            case .stopped, .starting, .capturing:
                break
            }
        case .starting, .capturing:
            break
        }
    }

    private func clearLocalPreview() {
        activePreviewGeneration = nil
        cameraPreviewImage = nil
    }

    private func invalidateLocalCapture() {
        activeCaptureGeneration = nil
        clearLocalPreview()
    }

    private func select(
        _ operation: () async throws -> String?,
        assign: (String?) -> Void
    ) async {
        mediaDisabled = await platform.isMediaDisabled()
        guard !mediaDisabled else {
            operatorError = "Media is disabled by ABBEY_MEDIA_DISABLED=1. Device selection was unchanged."
            return
        }
        do {
            assign(try await operation())
            operatorError = nil
        } catch {
            operatorError = Self.safeMessage(for: error)
        }
    }

    private static func safeMessage(for error: any Error) -> String {
        switch error {
        case MediaRuntimeError.unsupportedInputDevice:
            "The selected input device is unavailable."
        case MediaRuntimeError.unsupportedOutputDevice:
            "The selected output device is unavailable."
        case MediaRuntimeError.deviceSelectionRequiresStoppedEngine:
            "Stop local capture before changing its device."
        case MediaRuntimeError.disabledByEnvironment,
             VideoCaptureError.disabledByEnvironment:
            "Media is disabled by ABBEY_MEDIA_DISABLED=1."
        case let VideoCaptureError.permissionRequired(kind, _):
            kind == .camera
                ? "Camera permission is not granted. Local camera capture was not started."
                : "Screen Recording permission is not granted. Local screen capture was not started."
        case VideoCaptureError.sourceRequired, VideoCaptureError.unknownSource:
            "No local capture source is available."
        case VideoCaptureError.sourceRefreshRequiresStoppedCapture,
             VideoCaptureError.sourceSelectionRequiresStoppedCapture:
            "Local capture is already running. Stop it before starting another."
        default:
            "The local media operation failed. No media was sent."
        }
    }

    private static func qualificationMessage(_ error: any Error) -> String {
        switch error {
        case LiveMediaQualificationError.canaryDisabled:
            "Canary mode is disabled. Set ABBEY_MEDIA_QUALIFICATION_CANARY=1 for an authorized witnessed run."
        case LiveMediaQualificationError.managerUnauthorized:
            "Current Discord manager authorization could not be verified. Qualification stayed closed."
        case LiveMediaQualificationError.emptyParticipantSet:
            "No human participants are currently observed in that voice channel."
        case LiveMediaQualificationError.participantSetIncomplete:
            "Discord has not supplied a complete bounded participant set. Media stayed closed."
        case LiveMediaQualificationError.consentIncomplete:
            "Every currently observed participant must consent to the selected media capabilities."
        case LiveMediaQualificationError.epochMismatch:
            "The participant set changed. Media stopped and a fresh consent epoch is required."
        case LiveMediaQualificationError.unsupportedCodec,
             LiveMediaQualificationError.unsupportedDAVEVersion:
            "The observed DAVE/codec combination is not qualified; media stayed closed."
        default:
            "Live media qualification failed closed. No media was sent."
        }
    }

}
