import Testing
@testable import AbbeyCore

private enum VoiceControllerTestError: Error {
    case failed
}

private let testPair = DiscordVoiceGatewayPair(
    endpoint: "voice.secret.example",
    token: "super-secret-token",
    sessionID: "secret-session",
    serverID: "secret-guild",
    channelID: "secret-channel",
    userID: "secret-user"
)

private actor VoiceControllerTestBridge: DiscordVoiceGatewayPairBridge {
    enum PairBehavior: Sendable {
        case immediate
        case sleepUntilCancelled
        case fail
    }

    let pairBehavior: PairBehavior
    let failRequest: Bool
    private(set) var requestCount = 0
    private(set) var pairCount = 0
    private(set) var leaveCount = 0

    init(pairBehavior: PairBehavior = .immediate, failRequest: Bool = false) {
        self.pairBehavior = pairBehavior
        self.failRequest = failRequest
    }

    func requestGatewayState(guildID: String, channelID: String) async throws {
        requestCount += 1
        if failRequest { throw VoiceControllerTestError.failed }
    }

    func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair {
        pairCount += 1
        switch pairBehavior {
        case .immediate:
            return testPair
        case .sleepUntilCancelled:
            try await Task.sleep(for: .seconds(3_600))
            return testPair
        case .fail:
            throw VoiceControllerTestError.failed
        }
    }

    func leaveVoice(guildID: String) async {
        leaveCount += 1
    }
}

private actor VoiceControllerDeferredBridge: DiscordVoiceGatewayPairBridge {
    private var continuation: CheckedContinuation<DiscordVoiceGatewayPair, any Error>?
    private(set) var isWaiting = false

    func requestGatewayState(guildID: String, channelID: String) async throws {}

    func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair {
        isWaiting = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: testPair)
    }

    func leaveVoice(guildID: String) async {}
}

private actor VoiceControllerTestGateway: DiscordVoiceGatewaySessionClient {
    enum FailureStage: Sendable {
        case none
        case connect
        case select
        case media
    }

    let failureStage: FailureStage
    let capabilities: DiscordVoiceMediaCapabilities
    private(set) var connectCount = 0
    private(set) var mediaCount = 0
    private(set) var disconnectCount = 0

    init(
        failureStage: FailureStage = .none,
        capabilities: DiscordVoiceMediaCapabilities = .init(dave: true, aead: true, opus: true)
    ) {
        self.failureStage = failureStage
        self.capabilities = capabilities
    }

    func connect(using pair: DiscordVoiceGatewayPair) async throws -> DiscordVoiceGatewayTransportReady {
        connectCount += 1
        if failureStage == .connect { throw VoiceControllerTestError.failed }
        return .init(
            address: "127.0.0.1",
            port: 5_000,
            ssrc: 42,
            encryptionModes: ["aead_xchacha20_poly1305_rtpsize"]
        )
    }

    func selectTransport(_ endpoint: DiscordVoiceDiscoveredEndpoint) async throws {
        if failureStage == .select { throw VoiceControllerTestError.failed }
    }

    func negotiateDAVEAndMedia() async throws -> DiscordVoiceMediaCapabilities {
        mediaCount += 1
        if failureStage == .media { throw VoiceControllerTestError.failed }
        return capabilities
    }

    func disconnect() async {
        disconnectCount += 1
    }
}

private actor VoiceControllerSuspendedDisconnectGateway: DiscordVoiceGatewaySessionClient {
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var isDisconnectSuspended = false

    func connect(using pair: DiscordVoiceGatewayPair) async throws -> DiscordVoiceGatewayTransportReady {
        connectCount += 1
        return .init(
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
        guard disconnectCount == 1 else { return }
        isDisconnectSuspended = true
        await withCheckedContinuation { continuation in
            disconnectContinuation = continuation
        }
        isDisconnectSuspended = false
    }

    func resumeDisconnect() {
        let continuation = disconnectContinuation
        disconnectContinuation = nil
        continuation?.resume()
    }
}

private actor VoiceControllerTestUDP: DiscordVoiceUDPDiscoverySession {
    let fails: Bool
    private(set) var disconnectCount = 0

    init(fails: Bool = false) {
        self.fails = fails
    }

    func discoverEndpoint(
        for ready: DiscordVoiceGatewayTransportReady
    ) async throws -> DiscordVoiceDiscoveredEndpoint {
        if fails { throw VoiceControllerTestError.failed }
        return .init(address: "127.0.0.1", port: 6_000)
    }

    func disconnect() async {
        disconnectCount += 1
    }
}

private struct VoiceControllerTestFactory: DiscordVoiceSessionFactory {
    let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability
    let gateway: VoiceControllerTestGateway
    let udp: VoiceControllerTestUDP

    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient { gateway }
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession { udp }
}

@Suite("Discord Voice Controller")
struct DiscordVoiceControllerTests {
    private func configuration(
        timeout: Duration = .seconds(5),
        snapshotLimit: Int = 8,
        audioCapacity: Int = 2,
        videoCapacity: Int = 2
    ) throws -> DiscordVoiceControllerConfiguration {
        try .init(
            credentialTimeout: timeout,
            snapshotBufferLimit: snapshotLimit,
            audioQueueCapacity: audioCapacity,
            videoQueueCapacity: videoCapacity
        )
    }

    @Test("Unavailable production adapter stops honestly at media unavailable")
    func unavailableAdapterNeverBecomesReady() async throws {
        let bridge = VoiceControllerTestBridge()
        let gateway = VoiceControllerTestGateway()
        let controller = try DiscordVoiceController(
            bridge: bridge,
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .unavailable,
                gateway: gateway,
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration()
        )

        let snapshot = await controller.join(guildID: "guild", channelID: "channel")

        #expect(snapshot.phase == .failed)
        #expect(snapshot.failure == .mediaUnavailable)
        #expect(snapshot.mediaAdapterAvailable == false)
        #expect(await gateway.mediaCount == 0)
        #expect(snapshot.microphoneEnabled == false)
        #expect(snapshot.cameraEnabled == false)
        #expect(snapshot.screenShareEnabled == false)
        #expect(await gateway.disconnectCount == 1)
        #expect(await bridge.leaveCount == 1)
    }

    @Test("Credential wait is one-shot and timeout maps without connecting")
    func credentialTimeoutAndOneShot() async throws {
        let timingOutBridge = VoiceControllerTestBridge(pairBehavior: .sleepUntilCancelled)
        let gateway = VoiceControllerTestGateway()
        let controller = try DiscordVoiceController(
            bridge: timingOutBridge,
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .unavailable,
                gateway: gateway,
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration(),
            sleeper: { _ in }
        )

        let timeoutSnapshot = await controller.join(guildID: "g", channelID: "c")
        #expect(timeoutSnapshot.failure == .credentialTimedOut)
        #expect(await timingOutBridge.pairCount == 1)
        #expect(await gateway.connectCount == 0)
        #expect(await timingOutBridge.leaveCount == 1)

        let oneShotBridge = VoiceControllerTestBridge()
        let oneShotController = try DiscordVoiceController(
            bridge: oneShotBridge,
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .unavailable,
                gateway: VoiceControllerTestGateway(),
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration(),
            sleeper: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        _ = await oneShotController.join(guildID: "g", channelID: "c")
        #expect(await oneShotBridge.requestCount == 1)
        #expect(await oneShotBridge.pairCount == 1)
    }

    @Test("stopNow wins over a late credential and prevents resurrection")
    func stopNowPreventsResurrection() async throws {
        let bridge = VoiceControllerDeferredBridge()
        let gateway = VoiceControllerTestGateway()
        let controller = try DiscordVoiceController(
            bridge: bridge,
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .fullyWired,
                gateway: gateway,
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration(),
            sleeper: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        let join = Task { await controller.join(guildID: "g", channelID: "c") }
        while await bridge.isWaiting == false { await Task.yield() }

        await controller.stopNow()
        await bridge.resolve()
        let lateResult = await join.value
        let final = await controller.currentSnapshot()

        #expect(lateResult.phase == .idle)
        #expect(final.phase == .idle)
        #expect(final.generation > 1)
        #expect(final.microphoneEnabled == false)
        #expect(await gateway.connectCount == 0)
    }

    @Test("Failures map to their orchestration stage")
    func failureMapping() async throws {
        let bridgeFailure = try DiscordVoiceController(
            bridge: VoiceControllerTestBridge(failRequest: true),
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .fullyWired,
                gateway: VoiceControllerTestGateway(),
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration()
        )
        #expect(await bridgeFailure.join(guildID: "g", channelID: "c").failure == .bridgeUnavailable)

        let gatewayFailure = try DiscordVoiceController(
            bridge: VoiceControllerTestBridge(),
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .fullyWired,
                gateway: VoiceControllerTestGateway(failureStage: .connect),
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration()
        )
        #expect(await gatewayFailure.join(guildID: "g", channelID: "c").failure == .gatewayUnavailable)

        let transportFailure = try DiscordVoiceController(
            bridge: VoiceControllerTestBridge(),
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .fullyWired,
                gateway: VoiceControllerTestGateway(),
                udp: VoiceControllerTestUDP(fails: true)
            ),
            configuration: configuration()
        )
        #expect(await transportFailure.join(guildID: "g", channelID: "c").failure == .transportUnavailable)

        let mediaFailure = try DiscordVoiceController(
            bridge: VoiceControllerTestBridge(),
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .fullyWired,
                gateway: VoiceControllerTestGateway(
                    capabilities: .init(dave: true, aead: false, opus: true)
                ),
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration()
        )
        #expect(await mediaFailure.join(guildID: "g", channelID: "c").failure == .mediaUnavailable)
    }

    @Test("Bounded queues drop oldest and reject disabled or stale capture")
    func queueBackpressure() async throws {
        let controller = try DiscordVoiceController(
            bridge: VoiceControllerTestBridge(),
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .fullyWired,
                gateway: VoiceControllerTestGateway(),
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration(audioCapacity: 2)
        )
        let ready = await controller.join(guildID: "g", channelID: "c")
        #expect(ready.phase == .readyMuted)
        #expect(await controller.admit(.audio(audio(generation: ready.generation, byte: 0))) == .captureDisabled)
        _ = await controller.setMicrophoneEnabled(true)
        #expect(await controller.admit(.audio(audio(generation: ready.generation, byte: 1))) == .accepted)
        #expect(await controller.admit(.audio(audio(generation: ready.generation, byte: 2))) == .accepted)
        #expect(await controller.admit(.audio(audio(generation: ready.generation, byte: 3))) == .acceptedDroppingOldest)
        #expect(await controller.currentSnapshot().queuedAudioFrames == 2)
        #expect(await controller.currentSnapshot().droppedAudioFrames == 1)
        #expect(await controller.nextAudioFrame()?.bytes == [2])

        await controller.stopNow()
        #expect(await controller.admit(.audio(audio(generation: ready.generation, byte: 4))) == .staleGeneration)
    }

    @Test("Reconnect never restores microphone, camera, or screen capture")
    func reconnectDoesNotRestoreCapture() async throws {
        let controller = try DiscordVoiceController(
            bridge: VoiceControllerTestBridge(),
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .fullyWired,
                gateway: VoiceControllerTestGateway(),
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration()
        )
        _ = await controller.join(guildID: "g", channelID: "c")
        _ = await controller.setMicrophoneEnabled(true)
        _ = await controller.setCameraEnabled(true)
        _ = await controller.setScreenShareEnabled(true)
        _ = await controller.setSpeaking(true)

        let reconnected = await controller.reconnect()

        #expect(reconnected.phase == .readyMuted)
        #expect(reconnected.microphoneEnabled == false)
        #expect(reconnected.cameraEnabled == false)
        #expect(reconnected.screenShareEnabled == false)
    }

    @Test("Snapshots are bounded, redacted, immutable values and terminate on shutdown")
    func snapshotRedactionAndTermination() async throws {
        let controller = try DiscordVoiceController(
            bridge: VoiceControllerTestBridge(),
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .unavailable,
                gateway: VoiceControllerTestGateway(),
                udp: VoiceControllerTestUDP()
            ),
            configuration: configuration(snapshotLimit: 2)
        )
        let stream = await controller.snapshots()
        var iterator = stream.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        let rendered = initial.description
        let forbidden = ["secret", "token", "endpoint", "sessionID", "guildID", "channelID", "userID"]
        for value in forbidden {
            #expect(rendered.localizedCaseInsensitiveContains(value) == false)
            for child in Mirror(reflecting: initial).children {
                #expect(String(describing: child.value).localizedCaseInsensitiveContains(value) == false)
            }
        }

        _ = await controller.join(guildID: "secret-guild", channelID: "secret-channel")
        await controller.shutdown()

        var receivedAfterInitial = 0
        while await iterator.next() != nil {
            receivedAfterInitial += 1
            #expect(receivedAfterInitial <= 2)
        }
        #expect(receivedAfterInitial <= 2)
    }

    @Test("Gateway pair diagnostics redact all ephemeral capability fields")
    func gatewayPairDiagnosticsAreRedacted() {
        var dumped = ""
        dump(testPair, to: &dumped)
        let rendered = [
            String(describing: testPair),
            String(reflecting: testPair),
            dumped,
            Mirror(reflecting: testPair).children
                .map { String(reflecting: $0.value) }
                .joined(separator: " "),
        ]
        for value in rendered {
            #expect(!value.contains("voice.secret.example"))
            #expect(!value.contains("super-secret-token"))
            #expect(!value.contains("secret-session"))
            #expect(value.contains("redacted"))
        }
    }

    @Test("Replacement join tears down the previous transports before reconnecting")
    func replacementJoinTearsDownPreviousSession() async throws {
        let bridge = VoiceControllerTestBridge()
        let gateway = VoiceControllerTestGateway()
        let udp = VoiceControllerTestUDP()
        let controller = try DiscordVoiceController(
            bridge: bridge,
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .fullyWired,
                gateway: gateway,
                udp: udp
            ),
            configuration: configuration()
        )

        #expect(await controller.join(guildID: "first", channelID: "one").phase == .readyMuted)
        #expect(await controller.join(guildID: "second", channelID: "two").phase == .readyMuted)
        #expect(await gateway.disconnectCount == 1)
        #expect(await udp.disconnectCount == 1)
        #expect(await bridge.leaveCount == 1)
        #expect(await bridge.requestCount == 2)
    }

    @Test("suspended teardown finishes before replacement transport connects")
    func suspendedTeardownCannotCloseReplacement() async throws {
        let bridge = VoiceControllerTestBridge()
        let gateway = VoiceControllerSuspendedDisconnectGateway()
        let udp = VoiceControllerTestUDP()
        let factory = VoiceControllerSuspendedGatewayFactory(gateway: gateway, udp: udp)
        let controller = try DiscordVoiceController(
            bridge: bridge,
            factory: factory,
            configuration: configuration()
        )

        #expect(await controller.join(guildID: "first", channelID: "one").phase == .readyMuted)
        await controller.stopNow()
        while await gateway.isDisconnectSuspended == false { await Task.yield() }

        let replacement = Task {
            await controller.join(guildID: "second", channelID: "two")
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await gateway.connectCount == 1)
        #expect(await bridge.requestCount == 1)

        await gateway.resumeDisconnect()
        let result = await replacement.value
        #expect(result.phase == .readyMuted)
        #expect(await gateway.connectCount == 2)
        #expect(await bridge.requestCount == 2)
    }

    @Test("stop and repeated leave tear a session down once")
    func teardownIsIdempotent() async throws {
        let bridge = VoiceControllerTestBridge()
        let gateway = VoiceControllerTestGateway()
        let udp = VoiceControllerTestUDP()
        let controller = try DiscordVoiceController(
            bridge: bridge,
            factory: VoiceControllerTestFactory(
                mediaAdapterAvailability: .fullyWired,
                gateway: gateway,
                udp: udp
            ),
            configuration: configuration()
        )

        #expect(await controller.join(guildID: "guild", channelID: "channel").phase == .readyMuted)
        await controller.stopNow()
        async let firstLeave = controller.leave()
        async let secondLeave = controller.leave()
        _ = await (firstLeave, secondLeave)

        #expect(await gateway.disconnectCount == 1)
        #expect(await udp.disconnectCount == 1)
        #expect(await bridge.leaveCount == 1)
    }

    private func audio(generation: UInt64, byte: UInt8) -> DiscordVoiceOwnedAudioFrame {
        .init(generation: generation, captureTimestamp: UInt64(byte), sampleCount: 960, bytes: [byte])
    }
}

private struct VoiceControllerSuspendedGatewayFactory: DiscordVoiceSessionFactory {
    let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability = .fullyWired
    let gateway: VoiceControllerSuspendedDisconnectGateway
    let udp: VoiceControllerTestUDP

    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient { gateway }
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession { udp }
}
