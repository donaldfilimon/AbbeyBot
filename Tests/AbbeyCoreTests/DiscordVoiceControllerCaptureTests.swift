import Testing
@testable import AbbeyCore

private enum ControllerCaptureTestError: Error {
    case failed
}

private let capturePair = DiscordVoiceGatewayPair(
    endpoint: "voice.example",
    token: "token",
    sessionID: "session",
    serverID: "guild",
    channelID: "channel",
    userID: "user"
)

private actor ControllerCaptureBridge: DiscordVoiceGatewayPairBridge {
    private(set) var leaveCount = 0

    func requestGatewayState(guildID: String, channelID: String) async throws {}
    func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair { capturePair }
    func leaveVoice(guildID: String) async { leaveCount += 1 }
}

private actor ControllerCaptureOrderRecorder {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor ControllerCaptureGateway: DiscordVoiceGatewaySessionClient {
    private let recorder: ControllerCaptureOrderRecorder?
    private(set) var disconnectCount = 0

    init(recorder: ControllerCaptureOrderRecorder? = nil) {
        self.recorder = recorder
    }

    func connect(using pair: DiscordVoiceGatewayPair) async throws -> DiscordVoiceGatewayTransportReady {
        .init(
            address: "127.0.0.1",
            port: 5_000,
            ssrc: 42,
            encryptionModes: ["aead_xchacha20_poly1305_rtpsize"]
        )
    }

    func selectTransport(_ endpoint: DiscordVoiceDiscoveredEndpoint) async throws {}

    func negotiateDAVEAndMedia() async throws -> DiscordVoiceMediaCapabilities {
        .init(dave: true, aead: true, opus: true)
    }

    func disconnect() async {
        disconnectCount += 1
        await recorder?.record("gatewayDisconnect")
    }
}

private actor ControllerCaptureUDP: DiscordVoiceUDPDiscoverySession {
    private let recorder: ControllerCaptureOrderRecorder?

    init(recorder: ControllerCaptureOrderRecorder? = nil) {
        self.recorder = recorder
    }

    func discoverEndpoint(
        for ready: DiscordVoiceGatewayTransportReady
    ) async throws -> DiscordVoiceDiscoveredEndpoint {
        .init(address: "127.0.0.1", port: 6_000)
    }

    func disconnect() async {
        await recorder?.record("udpDisconnect")
    }
}

private actor ControllerCaptureLoopDouble: DiscordVoiceCaptureLoopControlling {
    private(set) var startGenerations: [UInt64] = []
    private(set) var stopCount = 0
    private var failStart = false
    private var terminalHandler: (@Sendable () async -> Void)?
    private let recorder: ControllerCaptureOrderRecorder?

    init(recorder: ControllerCaptureOrderRecorder? = nil) {
        self.recorder = recorder
    }

    func failNextStart() { failStart = true }

    func start(generation: UInt64) async throws {
        if failStart {
            failStart = false
            throw ControllerCaptureTestError.failed
        }
        startGenerations.append(generation)
        await recorder?.record("captureStart")
    }

    func stop() async {
        stopCount += 1
        await recorder?.record("captureStop")
    }

    func setTerminalHandler(_ handler: (@Sendable () async -> Void)?) {
        terminalHandler = handler
        if let handler {
            handlerHistory.append(handler)
        }
    }

    private var handlerHistory: [@Sendable () async -> Void] = []

    func hasTerminalHandler() -> Bool { terminalHandler != nil }

    func fireTerminal() async {
        await terminalHandler?()
    }

    /// Fires the terminal handler installed for an earlier generation even
    /// after a replacement session overwrote the current one.
    func fireTerminal(historyIndex: Int) async {
        guard handlerHistory.indices.contains(historyIndex) else { return }
        await handlerHistory[historyIndex]()
    }
}

private struct ControllerCaptureFactory: DiscordVoiceSessionFactory {
    let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability = .fullyWired
    let gateway: ControllerCaptureGateway
    let udp: ControllerCaptureUDP
    let loop: ControllerCaptureLoopDouble

    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient { gateway }
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession { udp }
    func makeSessionComponents() -> DiscordVoiceSessionComponents {
        DiscordVoiceSessionComponents(gateway: gateway, udp: udp, captureLoop: loop)
    }
}

@Suite("Discord Voice Controller capture composition")
struct DiscordVoiceControllerCaptureTests {
    private func makeController(
        bridge: ControllerCaptureBridge,
        factory: ControllerCaptureFactory
    ) throws -> DiscordVoiceController {
        try DiscordVoiceController(
            bridge: bridge,
            factory: factory,
            configuration: .init(
                credentialTimeout: .seconds(5),
                snapshotBufferLimit: 8,
                audioQueueCapacity: 2,
                videoQueueCapacity: 2
            )
        )
    }

    @Test("enabling the microphone starts the capture loop for the current generation; muting stops capture at the device boundary")
    func microphoneGatesCaptureLoop() async throws {
        let loop = ControllerCaptureLoopDouble()
        let controller = try makeController(
            bridge: ControllerCaptureBridge(),
            factory: ControllerCaptureFactory(
                gateway: ControllerCaptureGateway(),
                udp: ControllerCaptureUDP(),
                loop: loop
            )
        )

        let ready = await controller.join(guildID: "g", channelID: "c")
        #expect(ready.phase == .readyMuted)
        #expect(await loop.hasTerminalHandler())
        #expect(await loop.startGenerations.isEmpty)

        let enabled = await controller.setMicrophoneEnabled(true)
        #expect(enabled.microphoneEnabled)
        #expect(await loop.startGenerations == [ready.generation])
        #expect(await loop.stopCount == 0)

        // Re-enabling while already enabled must not restart capture.
        _ = await controller.setMicrophoneEnabled(true)
        #expect(await loop.startGenerations == [ready.generation])

        let muted = await controller.setMicrophoneEnabled(false)
        #expect(muted.microphoneEnabled == false)
        #expect(await loop.stopCount == 1)

        // Unmute starts capture again on the same generation.
        _ = await controller.setMicrophoneEnabled(true)
        #expect(await loop.startGenerations == [ready.generation, ready.generation])
        _ = await controller.leave()
    }

    @Test("leave stops capture before the gateway disconnect resets the media plane")
    func leaveStopsCaptureBeforeGatewayDisconnect() async throws {
        let recorder = ControllerCaptureOrderRecorder()
        let loop = ControllerCaptureLoopDouble(recorder: recorder)
        let controller = try makeController(
            bridge: ControllerCaptureBridge(),
            factory: ControllerCaptureFactory(
                gateway: ControllerCaptureGateway(recorder: recorder),
                udp: ControllerCaptureUDP(recorder: recorder),
                loop: loop
            )
        )

        _ = await controller.join(guildID: "g", channelID: "c")
        _ = await controller.setMicrophoneEnabled(true)
        _ = await controller.leave()

        #expect(await recorder.snapshot() == [
            "captureStart",
            "captureStop",
            "gatewayDisconnect",
            "udpDisconnect",
        ])
    }

    @Test("a capture-loop start failure fails closed: microphone stays disabled and the failure is operator-visible")
    func captureStartFailureFailsClosed() async throws {
        let loop = ControllerCaptureLoopDouble()
        await loop.failNextStart()
        let controller = try makeController(
            bridge: ControllerCaptureBridge(),
            factory: ControllerCaptureFactory(
                gateway: ControllerCaptureGateway(),
                udp: ControllerCaptureUDP(),
                loop: loop
            )
        )

        _ = await controller.join(guildID: "g", channelID: "c")
        let failed = await controller.setMicrophoneEnabled(true)

        #expect(failed.microphoneEnabled == false)
        #expect(failed.failure == .captureUnavailable)
        #expect(failed.phase == .readyMuted)
        #expect(await loop.startGenerations.isEmpty)

        // Signaling stays up; a retry can succeed.
        let retried = await controller.setMicrophoneEnabled(true)
        #expect(retried.microphoneEnabled)
        _ = await controller.leave()
    }

    @Test("a capture-loop terminal failure disables the microphone fail-closed")
    func captureTerminalDisablesMicrophone() async throws {
        let loop = ControllerCaptureLoopDouble()
        let controller = try makeController(
            bridge: ControllerCaptureBridge(),
            factory: ControllerCaptureFactory(
                gateway: ControllerCaptureGateway(),
                udp: ControllerCaptureUDP(),
                loop: loop
            )
        )

        _ = await controller.join(guildID: "g", channelID: "c")
        _ = await controller.setSpeaking(true)
        _ = await controller.setMicrophoneEnabled(true)
        _ = await controller.setSpeaking(true)
        #expect(await controller.currentSnapshot().phase == .readySpeaking)

        await loop.fireTerminal()

        let snapshot = await controller.currentSnapshot()
        #expect(snapshot.microphoneEnabled == false)
        #expect(snapshot.failure == .captureUnavailable)
        #expect(snapshot.phase == .readyMuted)
        _ = await controller.leave()
    }

    @Test("a stale terminal from an old generation cannot disable the replacement session's microphone")
    func staleTerminalIsIgnored() async throws {
        let loop = ControllerCaptureLoopDouble()
        let controller = try makeController(
            bridge: ControllerCaptureBridge(),
            factory: ControllerCaptureFactory(
                gateway: ControllerCaptureGateway(),
                udp: ControllerCaptureUDP(),
                loop: loop
            )
        )

        _ = await controller.join(guildID: "g", channelID: "c")
        _ = await controller.setMicrophoneEnabled(true)

        let replacement = await controller.join(guildID: "g", channelID: "c")
        #expect(replacement.phase == .readyMuted)
        _ = await controller.setMicrophoneEnabled(true)

        // Fire the terminal handler that belonged to the first generation.
        await loop.fireTerminal(historyIndex: 0)

        let snapshot = await controller.currentSnapshot()
        #expect(snapshot.microphoneEnabled == true)
        #expect(snapshot.failure == nil)
        _ = await controller.leave()
    }
}
