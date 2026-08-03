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
    let mediaAdapterAvailable: Bool

    init(_ snapshot: DiscordVoiceControllerSnapshot) {
        phase = snapshot.phase
        generation = snapshot.generation
        failure = snapshot.failure
        mediaAdapterAvailable = snapshot.mediaAdapterAvailable
    }

    static let idle = Self(
        phase: .idle,
        generation: 0,
        failure: nil,
        mediaAdapterAvailable: false
    )

    private init(
        phase: DiscordVoiceControllerPhase,
        generation: UInt64,
        failure: DiscordVoiceControllerFailure?,
        mediaAdapterAvailable: Bool
    ) {
        self.phase = phase
        self.generation = generation
        self.failure = failure
        self.mediaAdapterAvailable = mediaAdapterAvailable
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

    init(
        permissions: MediaPermissionController = MediaPermissionController(),
        audioCatalog: AudioDeviceCatalog = AudioDeviceCatalog(),
        audio: AVAudioEngineAdapter = AVAudioEngineAdapter(),
        video: VideoCaptureAdapter = VideoCaptureAdapter()
    ) {
        self.permissions = permissions
        self.audioCatalog = audioCatalog
        self.audio = audio
        self.video = video
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
    static let daveUnavailable = "DAVE unavailable — encrypted Discord media cannot start"
    static let captureUnavailable = "Capture/transmit disabled — Discord media is not shipped"
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
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var captureEventTask: Task<Void, Never>?
    @ObservationIgnored private var activeCaptureGeneration: UInt64?
    @ObservationIgnored private var activePreviewGeneration: UInt64?
    @ObservationIgnored private var localCaptureStartInFlight = false
    @ObservationIgnored private var operationGeneration: UInt64 = 0

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

    var signalingLabel: String { MediaSessionCopy.signaling(snapshot) }
    var transportLabel: String { MediaSessionCopy.transport(snapshot) }
    var daveLabel: String { MediaSessionCopy.daveUnavailable }
    var captureLabel: String { MediaSessionCopy.captureUnavailable }
    var localPreviewLabel: String { MediaSessionCopy.localPreviewOnly }
    var localCaptureActive: Bool {
        runtime.microphoneCapturing || runtime.cameraCapturing || runtime.screenCapturing
    }
    var localVideoCaptureActive: Bool {
        runtime.cameraCapturing || runtime.screenCapturing
    }

    init(controller: DiscordVoiceController, platform: any MediaSessionPlatform) {
        self.controller = controller
        self.platform = platform
        snapshot = .idle
        permissions = Dictionary(
            uniqueKeysWithValues: MediaPermissionKind.allCases.map { ($0, .notDetermined) }
        )
        observeController()
    }

    convenience init(discordBridge: DiscordBridge) {
        let configuration: DiscordVoiceControllerConfiguration
        do {
            configuration = try DiscordVoiceControllerConfiguration()
        } catch {
            preconditionFailure("Static voice-controller configuration is invalid")
        }
        let controller: DiscordVoiceController
        do {
            let factory: any DiscordVoiceSessionFactory
#if canImport(AbbeyMediaNative)
            factory = DiscordVoiceNativeControlSessionFactory()
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
        self.init(controller: controller, platform: MacOSMediaSessionPlatform())
    }

    func joinSignaling(guildID: String, channelID: String) async {
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
    }

    func leave() async {
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
    }

    func disconnect() async {
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
    }

    /// Awaited kill path: capture stops first, then generation invalidation and socket teardown.
    func stopAllMedia() async {
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
    }

    func shutdown() async {
        operationGeneration &+= 1
        snapshotTask?.cancel()
        snapshotTask = nil
        captureEventTask?.cancel()
        captureEventTask = nil
        invalidateLocalCapture()
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

}
