import AbbeyCore
import AbbeyMediaMacOS
import CoreVideo
import Foundation
import Testing
@testable import AbbeyBotApp

private enum MediaSessionTestFailure: Error {
    case unexpectedControllerUse
    case sensitiveRuntimeFailure
}

private actor MediaSessionTestBridge: DiscordVoiceGatewayPairBridge {
    func requestGatewayState(guildID: String, channelID: String) async throws {
        throw MediaSessionTestFailure.unexpectedControllerUse
    }

    func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair {
        throw MediaSessionTestFailure.unexpectedControllerUse
    }

    func leaveVoice(guildID: String) async {}
}

private actor SuspendingMediaSessionBridge: DiscordVoiceGatewayPairBridge {
    private var requestStarted = false
    private var requestContinuation: CheckedContinuation<Void, any Error>?
    private var leaveCount = 0

    func requestGatewayState(guildID: String, channelID: String) async throws {
        requestStarted = true
        try await withCheckedThrowingContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair {
        throw MediaSessionTestFailure.unexpectedControllerUse
    }

    func leaveVoice(guildID: String) async {
        leaveCount += 1
    }

    func didStartRequest() -> Bool { requestStarted }
    func leaveCalls() -> Int { leaveCount }

    func resumeRequest() {
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume()
    }
}

private actor MediaSessionTestGateway: DiscordVoiceGatewaySessionClient {
    func connect(using pair: DiscordVoiceGatewayPair) async throws -> DiscordVoiceGatewayTransportReady {
        throw MediaSessionTestFailure.unexpectedControllerUse
    }

    func selectTransport(_ endpoint: DiscordVoiceDiscoveredEndpoint) async throws {
        throw MediaSessionTestFailure.unexpectedControllerUse
    }

    func negotiateDAVEAndMedia() async throws -> DiscordVoiceMediaCapabilities {
        throw MediaSessionTestFailure.unexpectedControllerUse
    }

    func disconnect() async {}
}

private actor MediaSessionTestUDP: DiscordVoiceUDPDiscoverySession {
    func discoverEndpoint(
        for ready: DiscordVoiceGatewayTransportReady
    ) async throws -> DiscordVoiceDiscoveredEndpoint {
        throw MediaSessionTestFailure.unexpectedControllerUse
    }

    func disconnect() async {}
}

private struct MediaSessionTestFactory: DiscordVoiceSessionFactory {
    let mediaAdapterAvailability = DiscordVoiceMediaAdapterAvailability.unavailable

    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient {
        MediaSessionTestGateway()
    }

    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession {
        MediaSessionTestUDP()
    }
}

private struct MediaSessionPlatformCalls: Equatable, Sendable {
    var disabledChecks = 0
    var authorizationStatus: [MediaPermissionKind] = []
    var permissionRequests: [MediaPermissionKind] = []
    var deviceRefreshes = 0
    var inputSelections: [String?] = []
    var outputSelections: [String?] = []
    var runtimeSnapshots = 0
    var cameraStarts = 0
    var screenStarts = 0
    var stopCalls = 0
}

private actor FakeMediaSessionPlatform: MediaSessionPlatform {
    private var calls = MediaSessionPlatformCalls()
    private var disabled: Bool
    private var statuses: [MediaPermissionKind: MediaAuthorizationStatus]
    private var requestedStatuses: [MediaPermissionKind: MediaAuthorizationStatus]
    private var devices: [MediaSessionDevice]
    private var runtime: MediaSessionRuntimeSnapshot
    private var permissionFails = false
    private var inputError: MediaRuntimeError?
    private var outputError: MediaRuntimeError?
    private var captureStartError: VideoCaptureError?
    private var shouldSuspendNextStop = false
    private var pendingStop: CheckedContinuation<Void, Never>?
    private var shouldSuspendNextRuntimeSnapshot = false
    private var pendingRuntimeSnapshot: CheckedContinuation<MediaSessionRuntimeSnapshot, Never>?
    private var pendingRuntimeSnapshotValue: MediaSessionRuntimeSnapshot?
    private var runtimeSnapshotSuspensionObservers: [CheckedContinuation<Void, Never>] = []
    private var captureGeneration: UInt64 = 0
    private let captureEventStream: AsyncStream<VideoCaptureEvent>
    private let captureEventContinuation: AsyncStream<VideoCaptureEvent>.Continuation

    init(
        disabled: Bool = false,
        statuses: [MediaPermissionKind: MediaAuthorizationStatus] = [:],
        requestedStatuses: [MediaPermissionKind: MediaAuthorizationStatus] = [:],
        devices: [MediaSessionDevice] = [],
        runtime: MediaSessionRuntimeSnapshot = .stopped
    ) {
        let eventPair = AsyncStream<VideoCaptureEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        captureEventStream = eventPair.stream
        captureEventContinuation = eventPair.continuation
        self.disabled = disabled
        self.statuses = statuses
        self.requestedStatuses = requestedStatuses
        self.devices = devices
        self.runtime = runtime
    }

    func isMediaDisabled() async -> Bool {
        calls.disabledChecks += 1
        return disabled
    }

    func authorizationStatus(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus {
        calls.authorizationStatus.append(kind)
        return statuses[kind] ?? .notDetermined
    }

    func requestAuthorization(for kind: MediaPermissionKind) async throws -> MediaAuthorizationStatus {
        calls.permissionRequests.append(kind)
        if permissionFails {
            throw MediaSessionTestFailure.sensitiveRuntimeFailure
        }
        return requestedStatuses[kind] ?? .notDetermined
    }

    func refreshAudioDevices() async -> [MediaSessionDevice] {
        calls.deviceRefreshes += 1
        return devices
    }

    func selectInput(uid: String?) async throws -> String? {
        calls.inputSelections.append(uid)
        if let inputError { throw inputError }
        return uid
    }

    func selectOutput(uid: String?) async throws -> String? {
        calls.outputSelections.append(uid)
        if let outputError { throw outputError }
        return uid
    }

    func runtimeSnapshot() async -> MediaSessionRuntimeSnapshot {
        calls.runtimeSnapshots += 1
        let capturedRuntime = runtime
        guard shouldSuspendNextRuntimeSnapshot else { return capturedRuntime }
        shouldSuspendNextRuntimeSnapshot = false
        return await withCheckedContinuation { continuation in
            pendingRuntimeSnapshot = continuation
            pendingRuntimeSnapshotValue = capturedRuntime
            let observers = runtimeSnapshotSuspensionObservers
            runtimeSnapshotSuspensionObservers.removeAll()
            observers.forEach { $0.resume() }
        }
    }

    func startCameraCapture() async throws -> UInt64 {
        calls.cameraStarts += 1
        if let captureStartError { throw captureStartError }
        captureGeneration &+= 1
        runtime = MediaSessionRuntimeSnapshot(
            microphoneCapturing: false,
            cameraCapturing: true,
            screenCapturing: false,
            inputLevel: 0,
            outputLevel: 0
        )
        publishStatus(.capturing)
        return captureGeneration
    }

    func startScreenCapture() async throws -> UInt64 {
        calls.screenStarts += 1
        if let captureStartError { throw captureStartError }
        captureGeneration &+= 1
        runtime = MediaSessionRuntimeSnapshot(
            microphoneCapturing: false,
            cameraCapturing: false,
            screenCapturing: true,
            inputLevel: 0,
            outputLevel: 0
        )
        publishStatus(.capturing)
        return captureGeneration
    }

    func captureEvents() -> AsyncStream<VideoCaptureEvent> {
        captureEventStream
    }

    func stopAllCapture() async {
        calls.stopCalls += 1
        captureGeneration &+= 1
        runtime = .stopped
        publishStatus(.stopped)
        guard shouldSuspendNextStop else { return }
        shouldSuspendNextStop = false
        await withCheckedContinuation { continuation in
            pendingStop = continuation
        }
    }

    func callSnapshot() -> MediaSessionPlatformCalls { calls }

    func failPermissionRequests() {
        permissionFails = true
    }

    func failInputSelection(with error: MediaRuntimeError) {
        inputError = error
    }

    func failOutputSelection(with error: MediaRuntimeError) {
        outputError = error
    }

    func failCaptureStarts(with error: VideoCaptureError) {
        captureStartError = error
    }

    func suspendNextStop() {
        shouldSuspendNextStop = true
    }

    func releaseStop() {
        let continuation = pendingStop
        pendingStop = nil
        continuation?.resume()
    }

    func suspendNextRuntimeSnapshot() {
        shouldSuspendNextRuntimeSnapshot = true
    }

    func waitForRuntimeSnapshotSuspension() async {
        guard pendingRuntimeSnapshot == nil else { return }
        await withCheckedContinuation { continuation in
            runtimeSnapshotSuspensionObservers.append(continuation)
        }
    }

    func releaseRuntimeSnapshot() {
        let continuation = pendingRuntimeSnapshot
        let snapshot = pendingRuntimeSnapshotValue ?? runtime
        pendingRuntimeSnapshot = nil
        pendingRuntimeSnapshotValue = nil
        continuation?.resume(returning: snapshot)
    }

    func currentCaptureGeneration() -> UInt64 { captureGeneration }

    func emitFrame(_ frame: OwnedVideoFrame, generation: UInt64) {
        _ = captureEventContinuation.yield(.frame(generation: generation, frame: frame))
    }

    func emitTerminalState(_ state: VideoCaptureState) {
        captureGeneration &+= 1
        runtime = .stopped
        publishStatus(state)
    }

    private func publishStatus(_ state: VideoCaptureState) {
        _ = captureEventContinuation.yield(
            .status(
                VideoCaptureStatusSnapshot(
                    state: state,
                    selectedSource: nil,
                    droppedSourceFrames: 0,
                    droppedConsumerFrames: 0,
                    generation: captureGeneration
                )
            )
        )
    }
}

private actor MediaSessionCompletionProbe {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

@Suite("Media Session Model")
@MainActor
struct MediaSessionModelTests {
    private func makeController() throws -> DiscordVoiceController {
        try DiscordVoiceController(
            bridge: MediaSessionTestBridge(),
            factory: MediaSessionTestFactory(),
            configuration: DiscordVoiceControllerConfiguration()
        )
    }

    @Test("Construction is passive and does not inspect permissions or devices")
    func constructionHasNoPlatformSideEffects() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        for _ in 0..<4 { await Task.yield() }

        #expect(await platform.callSnapshot() == MediaSessionPlatformCalls())
        #expect(model.permissions.values.allSatisfy { $0 == .notDetermined })
        #expect(model.devices.isEmpty)
        await model.shutdown()
    }

    @Test("Disabled policy blocks explicit prompt, enumeration, and selection calls")
    func disabledPolicyFailsClosedBeforePlatformActions() async throws {
        let platform = FakeMediaSessionPlatform(disabled: true)
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.requestPermission(.microphone)
        #expect(model.permissionStatus(.microphone) == .unavailable)
        #expect(model.operatorError == "Media is disabled by ABBEY_MEDIA_DISABLED=1. No permission request was made.")

        await model.refreshDevices()
        #expect(model.devices.isEmpty)
        #expect(model.operatorError == "Media is disabled by ABBEY_MEDIA_DISABLED=1. No devices were enumerated.")

        await model.selectInput(uid: "private-input-uid")
        #expect(model.operatorError == "Media is disabled by ABBEY_MEDIA_DISABLED=1. Device selection was unchanged.")
        await model.selectOutput(uid: "private-output-uid")

        let calls = await platform.callSnapshot()
        #expect(calls.disabledChecks == 4)
        #expect(calls.permissionRequests.isEmpty)
        #expect(calls.deviceRefreshes == 0)
        #expect(calls.inputSelections.isEmpty)
        #expect(calls.outputSelections.isEmpty)
        await model.shutdown()
    }

    @Test("Explicit permission, discovery, and device selection update only session state")
    func explicitPermissionAndDeviceFlow() async throws {
        let input = MediaSessionDevice(
            id: "input-1",
            name: "Studio Mic",
            supportsInput: true,
            supportsOutput: false,
            isDefaultInput: true,
            isDefaultOutput: false
        )
        let output = MediaSessionDevice(
            id: "output-1",
            name: "Studio Monitor",
            supportsInput: false,
            supportsOutput: true,
            isDefaultInput: false,
            isDefaultOutput: true
        )
        let platform = FakeMediaSessionPlatform(
            statuses: [.microphone: .denied, .camera: .authorized],
            requestedStatuses: [.microphone: .authorized],
            devices: [input, output]
        )
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.refreshPrivacyStatus()
        #expect(model.permissionStatus(.microphone) == .denied)
        #expect(model.permissionStatus(.camera) == .authorized)

        await model.requestPermission(.microphone)
        await model.refreshDevices()
        await model.selectInput(uid: input.id)
        await model.selectOutput(uid: output.id)

        #expect(model.permissionStatus(.microphone) == .authorized)
        #expect(model.devices == [input, output])
        #expect(model.selectedInputUID == input.id)
        #expect(model.selectedOutputUID == output.id)
        #expect(model.operatorError == nil)

        let calls = await platform.callSnapshot()
        #expect(Set(calls.authorizationStatus) == Set(MediaPermissionKind.allCases))
        #expect(calls.permissionRequests == [.microphone])
        #expect(calls.deviceRefreshes == 1)
        #expect(calls.inputSelections == [input.id])
        #expect(calls.outputSelections == [output.id])
        await model.shutdown()
    }

    @Test("Stop and shutdown await capture teardown and remain idempotent")
    func stopAndShutdownAreAwaitedAndIdempotent() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)
        let completion = MediaSessionCompletionProbe()
        await platform.suspendNextStop()

        let blockedStop = Task { @MainActor in
            await model.stopAllMedia()
            await completion.markCompleted()
        }
        for _ in 0..<100 {
            if await platform.callSnapshot().stopCalls == 1 { break }
            await Task.yield()
        }

        #expect(await platform.callSnapshot().stopCalls == 1)
        #expect(await completion.isCompleted() == false)
        await platform.releaseStop()
        await blockedStop.value
        #expect(await completion.isCompleted())

        await model.stopAllMedia()
        await model.shutdown()
        await model.shutdown()

        #expect(await platform.callSnapshot().stopCalls == 4)
        #expect(model.snapshot.phase == .idle)
        #expect(model.runtime == .stopped)
        #expect(model.operatorError == nil)
    }

    @Test("Disconnect preempts suspended join and rejects its late completion")
    func disconnectPreemptsSuspendedJoin() async throws {
        let bridge = SuspendingMediaSessionBridge()
        let platform = FakeMediaSessionPlatform()
        let controller = try DiscordVoiceController(
            bridge: bridge,
            factory: MediaSessionTestFactory(),
            configuration: DiscordVoiceControllerConfiguration()
        )
        let model = MediaSessionModel(controller: controller, platform: platform)

        let join = Task { @MainActor in
            await model.joinSignaling(guildID: "guild", channelID: "channel")
        }
        for _ in 0..<100 {
            if await bridge.didStartRequest() { break }
            await Task.yield()
        }
        #expect(await bridge.didStartRequest())
        #expect(model.isOperationInFlight)

        await model.disconnect()
        #expect(model.snapshot.phase == .idle)
        #expect(model.isOperationInFlight == false)
        #expect(await bridge.leaveCalls() == 1)

        await bridge.resumeRequest()
        await join.value
        for _ in 0..<4 { await Task.yield() }

        #expect(model.snapshot.phase == .idle)
        #expect(model.isOperationInFlight == false)
        #expect(await bridge.leaveCalls() == 1)
        await model.shutdown()
    }

    @Test("Platform failures map to fixed operator-safe messages")
    func platformErrorsAreRedacted() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await platform.failPermissionRequests()
        await model.requestPermission(.camera)
        #expect(model.operatorError == "The local media operation failed. No media was sent.")

        await platform.failInputSelection(with: .unsupportedInputDevice)
        await model.selectInput(uid: "secret-input-uid")
        #expect(model.operatorError == "The selected input device is unavailable.")

        await platform.failOutputSelection(with: .runtimeFailure("token=do-not-display"))
        await model.selectOutput(uid: "secret-output-uid")
        #expect(model.operatorError == "The local media operation failed. No media was sent.")
        #expect(model.operatorError?.contains("token") == false)
        #expect(model.operatorError?.contains("secret-output-uid") == false)
        await model.shutdown()
    }

    @Test("Explicit camera start flips local capture state and clears errors")
    func startCameraCaptureHappyPath() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.startCameraCapture()

        #expect(model.runtime.cameraCapturing)
        #expect(model.runtime.screenCapturing == false)
        #expect(model.localCaptureActive)
        #expect(model.operatorError == nil)
        #expect(model.isOperationInFlight == false)
        let calls = await platform.callSnapshot()
        #expect(calls.cameraStarts == 1)
        #expect(calls.screenStarts == 0)
        await model.shutdown()
    }

    @Test("Explicit screen start flips local capture state")
    func startScreenCaptureHappyPath() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.startScreenCapture()

        #expect(model.runtime.screenCapturing)
        #expect(model.runtime.cameraCapturing == false)
        #expect(model.localCaptureActive)
        #expect(model.operatorError == nil)
        #expect(await platform.callSnapshot().screenStarts == 1)
        await model.shutdown()
    }

    @Test("Camera permission denial fails closed with an operator-visible error")
    func startCameraCapturePermissionDeniedFailsClosed() async throws {
        let platform = FakeMediaSessionPlatform()
        await platform.failCaptureStarts(with: .permissionRequired(.camera, .denied))
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.startCameraCapture()

        #expect(model.runtime == .stopped)
        #expect(model.localCaptureActive == false)
        #expect(model.cameraPreviewImage == nil)
        #expect(model.operatorError == "Camera permission is not granted. Local camera capture was not started.")

        await platform.failCaptureStarts(with: .permissionRequired(.screen, .denied))
        await model.startScreenCapture()
        #expect(model.operatorError == "Screen Recording permission is not granted. Local screen capture was not started.")
        await model.shutdown()
    }

    @Test("Disabled policy blocks local capture start before any platform action")
    func disabledPolicyBlocksLocalCaptureStart() async throws {
        let platform = FakeMediaSessionPlatform(disabled: true)
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.startCameraCapture()

        #expect(model.operatorError == "Media is disabled by ABBEY_MEDIA_DISABLED=1. Local capture was not started.")
        #expect(model.runtime == .stopped)
        let calls = await platform.callSnapshot()
        #expect(calls.cameraStarts == 0)
        #expect(calls.screenStarts == 0)
        await model.shutdown()
    }

    @Test("Kill switch stops an active local capture and clears the preview")
    func killSwitchStopsActiveCapture() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.startCameraCapture()
        #expect(model.runtime.cameraCapturing)

        await model.stopAllMedia()

        #expect(model.runtime == .stopped)
        #expect(model.localCaptureActive == false)
        #expect(model.cameraPreviewImage == nil)
        #expect(model.operatorError == nil)
        #expect(await platform.callSnapshot().stopCalls == 1)
        await model.shutdown()
    }

    @Test("stopLocalCapture is idempotent and never invents errors")
    func stopLocalCaptureIsIdempotent() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.startCameraCapture()
        await model.stopLocalCapture()
        await model.stopLocalCapture()

        #expect(model.runtime == .stopped)
        #expect(model.localCaptureActive == false)
        #expect(model.cameraPreviewImage == nil)
        #expect(model.operatorError == nil)
        #expect(await platform.callSnapshot().stopCalls == 2)
        await model.shutdown()
    }

    @Test("BGRA frames render to a bounded CGImage; other formats are rejected")
    func previewRendererConvertsOnlyBGRA() throws {
        let bgra = try OwnedVideoFrame(
            width: 2,
            height: 2,
            bytesPerRow: 8,
            presentationTimeNanoseconds: 1,
            bytes: Data([
                0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF,
                0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
            ])
        )
        let image = VideoFramePreviewRenderer.makeCGImage(from: bgra)
        #expect(image != nil)
        #expect(image?.width == 2)
        #expect(image?.height == 2)
        #expect(image?.bitsPerPixel == 32)

        let nonBGRA = try OwnedVideoFrame(
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            presentationTimeNanoseconds: 1,
            bytes: Data(count: 16)
        )
        #expect(VideoFramePreviewRenderer.makeCGImage(from: nonBGRA) == nil)
    }

    @Test("A frame buffered by an old capture generation never renders after restart")
    func staleCaptureGenerationCannotRenderAfterRestart() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.startCameraCapture()
        let firstGeneration = await platform.currentCaptureGeneration()
        await model.stopLocalCapture()
        await model.startCameraCapture()
        let currentGeneration = await platform.currentCaptureGeneration()
        #expect(currentGeneration > firstGeneration)

        await platform.emitFrame(try previewFrame(marker: 0x11), generation: firstGeneration)
        for _ in 0..<100 { await Task.yield() }
        #expect(model.cameraPreviewImage == nil)

        await platform.emitFrame(try previewFrame(marker: 0x22), generation: currentGeneration)
        for _ in 0..<100 {
            if model.cameraPreviewImage != nil { break }
            await Task.yield()
        }
        #expect(model.cameraPreviewImage != nil)
        await model.shutdown()
    }

    @Test("Terminal adapter states erase preview pixels and mark video capture stopped")
    func terminalAdapterStatesClearPreview() async throws {
        let terminalStates: [VideoCaptureState] = [
            .interrupted,
            .sourceUnavailable,
            .failed("redacted adapter failure")
        ]

        for terminalState in terminalStates {
            let platform = FakeMediaSessionPlatform()
            let model = MediaSessionModel(controller: try makeController(), platform: platform)
            await model.startCameraCapture()
            let generation = await platform.currentCaptureGeneration()
            await platform.emitFrame(try previewFrame(marker: 0x33), generation: generation)
            for _ in 0..<100 {
                if model.cameraPreviewImage != nil { break }
                await Task.yield()
            }
            #expect(model.cameraPreviewImage != nil)

            await platform.emitTerminalState(terminalState)
            for _ in 0..<100 {
                if model.cameraPreviewImage == nil, !model.runtime.cameraCapturing { break }
                await Task.yield()
            }
            #expect(model.cameraPreviewImage == nil)
            #expect(model.runtime.cameraCapturing == false)
            #expect(model.runtime.screenCapturing == false)
            #expect(model.localCaptureActive == false)
            await model.shutdown()
        }
    }

    @Test("Terminal status during a suspended runtime snapshot cannot restore stale capture state")
    func terminalDuringRuntimeSnapshotCannotReactivatePreview() async throws {
        let platform = FakeMediaSessionPlatform()
        await platform.suspendNextRuntimeSnapshot()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        let start = Task { await model.startCameraCapture() }
        await platform.waitForRuntimeSnapshotSuspension()
        let generation = await platform.currentCaptureGeneration()
        await platform.emitFrame(try previewFrame(marker: 0x44), generation: generation)
        for _ in 0..<100 {
            if model.cameraPreviewImage != nil { break }
            await Task.yield()
        }
        #expect(model.cameraPreviewImage != nil)

        await platform.emitTerminalState(.interrupted)
        for _ in 0..<100 {
            if model.cameraPreviewImage == nil, !model.localVideoCaptureActive { break }
            await Task.yield()
        }

        #expect(model.cameraPreviewImage == nil)
        #expect(model.localVideoCaptureActive == false)
        await platform.releaseRuntimeSnapshot()
        await start.value

        #expect(model.cameraPreviewImage == nil)
        #expect(model.runtime.cameraCapturing == false)
        #expect(model.runtime.screenCapturing == false)
        #expect(model.localVideoCaptureActive == false)
        #expect(model.isOperationInFlight == false)
        await model.shutdown()
    }

    @Test("A second video start is rejected without invalidating the active preview")
    func secondStartPreservesActiveCapture() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)
        await model.startCameraCapture()
        let generation = await platform.currentCaptureGeneration()
        await platform.emitFrame(try previewFrame(marker: 0x55), generation: generation)
        for _ in 0..<100 {
            if model.cameraPreviewImage != nil { break }
            await Task.yield()
        }
        #expect(model.cameraPreviewImage != nil)

        await model.startScreenCapture()

        #expect(model.runtime.cameraCapturing)
        #expect(model.runtime.screenCapturing == false)
        #expect(model.cameraPreviewImage != nil)
        #expect(model.operatorError == "Local capture is already running. Stop it before starting another.")
        let calls = await platform.callSnapshot()
        #expect(calls.cameraStarts == 1)
        #expect(calls.screenStarts == 0)
        await model.shutdown()
    }

    @Test("Discord view disappearance stops active or starting preview but is passive while idle")
    func viewDisappearanceStopsOnlyActivePreview() async throws {
        let platform = FakeMediaSessionPlatform()
        let model = MediaSessionModel(controller: try makeController(), platform: platform)

        await model.stopLocalCaptureWhenViewDisappears()
        #expect(await platform.callSnapshot().stopCalls == 0)

        await model.startCameraCapture()
        await model.stopLocalCaptureWhenViewDisappears()

        #expect(model.cameraPreviewImage == nil)
        #expect(model.localVideoCaptureActive == false)
        #expect(model.runtime == .stopped)
        #expect(await platform.callSnapshot().stopCalls == 1)
        await model.shutdown()

        let startingPlatform = FakeMediaSessionPlatform()
        await startingPlatform.suspendNextRuntimeSnapshot()
        let startingModel = MediaSessionModel(
            controller: try makeController(),
            platform: startingPlatform
        )
        let start = Task { await startingModel.startCameraCapture() }
        await startingPlatform.waitForRuntimeSnapshotSuspension()

        await startingModel.stopLocalCaptureWhenViewDisappears()
        await startingPlatform.releaseRuntimeSnapshot()
        await start.value

        #expect(startingModel.cameraPreviewImage == nil)
        #expect(startingModel.localVideoCaptureActive == false)
        #expect(startingModel.runtime == .stopped)
        #expect(await startingPlatform.callSnapshot().stopCalls == 1)
        await startingModel.shutdown()
    }

    private func previewFrame(marker: UInt8) throws -> OwnedVideoFrame {
        try OwnedVideoFrame(
            width: 1,
            height: 1,
            bytesPerRow: 4,
            presentationTimeNanoseconds: UInt64(marker),
            bytes: Data(repeating: marker, count: 4)
        )
    }
}
