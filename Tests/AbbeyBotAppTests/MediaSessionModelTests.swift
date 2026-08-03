import AbbeyCore
import AbbeyMediaMacOS
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
    private var shouldSuspendNextStop = false
    private var pendingStop: CheckedContinuation<Void, Never>?

    init(
        disabled: Bool = false,
        statuses: [MediaPermissionKind: MediaAuthorizationStatus] = [:],
        requestedStatuses: [MediaPermissionKind: MediaAuthorizationStatus] = [:],
        devices: [MediaSessionDevice] = [],
        runtime: MediaSessionRuntimeSnapshot = .stopped
    ) {
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
        return runtime
    }

    func stopAllCapture() async {
        calls.stopCalls += 1
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

    func suspendNextStop() {
        shouldSuspendNextStop = true
    }

    func releaseStop() {
        let continuation = pendingStop
        pendingStop = nil
        continuation?.resume()
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
}
