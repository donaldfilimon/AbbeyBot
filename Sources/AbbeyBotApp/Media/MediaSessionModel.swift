import AbbeyCore
import AbbeyMediaMacOS
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

    func stopAllCapture() async {
        await video.killSwitch()
        await audio.stopNow()
    }
}

enum MediaSessionCopy {
    static let daveUnavailable = "DAVE unavailable — encrypted Discord media cannot start"
    static let captureUnavailable = "Capture/transmit disabled — Discord media is not shipped"
    static let sessionOnlySelection = "Device selections are session-only and are not persisted"

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

    var signalingLabel: String { MediaSessionCopy.signaling(snapshot) }
    var transportLabel: String { MediaSessionCopy.transport(snapshot) }
    var daveLabel: String { MediaSessionCopy.daveUnavailable }
    var captureLabel: String { MediaSessionCopy.captureUnavailable }

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
        case MediaRuntimeError.disabledByEnvironment:
            "Media is disabled by ABBEY_MEDIA_DISABLED=1."
        default:
            "The local media operation failed. No media was sent."
        }
    }

}
