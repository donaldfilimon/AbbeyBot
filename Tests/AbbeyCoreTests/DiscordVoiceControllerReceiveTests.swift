import Testing
@testable import AbbeyCore

private enum ControllerReceiveTestError: Error {
    case failed
}

private let receivePair = DiscordVoiceGatewayPair(
    endpoint: "voice.example",
    token: "token",
    sessionID: "session",
    serverID: "guild",
    channelID: "channel",
    userID: "user"
)

private actor ControllerReceiveBridge: DiscordVoiceGatewayPairBridge {
    private(set) var leaveCount = 0

    func requestGatewayState(guildID: String, channelID: String) async throws {}
    func awaitGatewayPair() async throws -> DiscordVoiceGatewayPair { receivePair }
    func leaveVoice(guildID: String) async { leaveCount += 1 }
}

private actor ControllerReceiveOrderRecorder {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor ControllerReceiveGateway: DiscordVoiceGatewaySessionClient {
    private let recorder: ControllerReceiveOrderRecorder?
    private let negotiates: Bool

    init(recorder: ControllerReceiveOrderRecorder? = nil, negotiates: Bool = true) {
        self.recorder = recorder
        self.negotiates = negotiates
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
        guard negotiates else { throw ControllerReceiveTestError.failed }
        return .init(dave: true, aead: true, opus: true)
    }

    func disconnect() async {
        await recorder?.record("gatewayDisconnect")
    }
}

private actor ControllerReceiveUDP: DiscordVoiceUDPDiscoverySession {
    private let recorder: ControllerReceiveOrderRecorder?

    init(recorder: ControllerReceiveOrderRecorder? = nil) {
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

/// Receive-loop double built on the same deterministic reentrancy harness the
/// capture-loop double uses: `gateNextStart()` parks the controller *inside*
/// `await receiveLoop.start(...)` so a test can land a terminal verdict in that
/// exact window.
private actor ControllerReceiveLoopDouble: DiscordVoiceReceiveLoopControlling {
    private(set) var startGenerations: [UInt64] = []
    private(set) var stopCount = 0
    private var failStart = false
    private var terminalHandler: (@Sendable () async -> Void)?
    private let recorder: ControllerReceiveOrderRecorder?

    private var gateNextStartCall = false
    private var startEntered = false
    private var startReleased = false
    private var startEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var startReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(recorder: ControllerReceiveOrderRecorder? = nil) {
        self.recorder = recorder
    }

    func failNextStart() { failStart = true }

    func gateNextStart() {
        gateNextStartCall = true
        startEntered = false
        startReleased = false
    }

    func waitForStartEntry() async {
        if startEntered { return }
        await withCheckedContinuation { startEntryWaiters.append($0) }
    }

    func releaseStart() {
        startReleased = true
        let waiters = startReleaseWaiters
        startReleaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func start(generation: UInt64) async throws {
        if gateNextStartCall {
            gateNextStartCall = false
            startEntered = true
            let waiters = startEntryWaiters
            startEntryWaiters = []
            for waiter in waiters { waiter.resume() }
            if !startReleased {
                await withCheckedContinuation { startReleaseWaiters.append($0) }
            }
        }
        if failStart {
            failStart = false
            throw ControllerReceiveTestError.failed
        }
        startGenerations.append(generation)
        await recorder?.record("receiveStart")
    }

    func stop() async {
        stopCount += 1
        await recorder?.record("receiveStop")
    }

    func setTerminalHandler(_ handler: (@Sendable () async -> Void)?) {
        terminalHandler = handler
    }

    func hasTerminalHandler() -> Bool { terminalHandler != nil }

    func fireTerminal() async {
        await terminalHandler?()
    }
}

private struct ControllerReceiveFactory: DiscordVoiceSessionFactory {
    let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability = .fullyWired
    let gateway: ControllerReceiveGateway
    let udp: ControllerReceiveUDP
    let receiveLoop: ControllerReceiveLoopDouble

    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient { gateway }
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession { udp }
    func makeSessionComponents() -> DiscordVoiceSessionComponents {
        DiscordVoiceSessionComponents(gateway: gateway, udp: udp, receiveLoop: receiveLoop)
    }
}

@Suite("Discord Voice Controller receive composition")
struct DiscordVoiceControllerReceiveTests {
    private func makeController(
        bridge: ControllerReceiveBridge,
        factory: ControllerReceiveFactory
    ) throws -> DiscordVoiceController {
        try DiscordVoiceController(
            bridge: bridge,
            factory: factory,
            configuration: .init(
                credentialTimeout: .seconds(5),
                snapshotBufferLimit: 8
            )
        )
    }

    @Test("A ready session does NOT start receive; the operator toggle does")
    func receiveLoopStartsOnlyWhenOperatorEnablesIt() async throws {
        let loop = ControllerReceiveLoopDouble()
        let factory = ControllerReceiveFactory(
            gateway: ControllerReceiveGateway(),
            udp: ControllerReceiveUDP(),
            receiveLoop: loop
        )
        let controller = try makeController(bridge: ControllerReceiveBridge(), factory: factory)
        let snapshot = await controller.join(guildID: "g", channelID: "c")
        #expect(snapshot.phase == .readyMuted)
        // Receiving decrypts other members' speech, so joining a channel must
        // never start it implicitly. The terminal handler is registered up
        // front, but no start has happened.
        #expect(!snapshot.receiveActive)
        #expect(snapshot.failure == nil)
        #expect(await loop.startGenerations.isEmpty)
        #expect(await loop.hasTerminalHandler())

        let enabled = await controller.setReceiveEnabled(true)
        #expect(enabled.receiveActive)
        #expect(await loop.startGenerations == [snapshot.generation])

        // And the operator can turn it back off, with the loop drained.
        let disabled = await controller.setReceiveEnabled(false)
        #expect(!disabled.receiveActive)
        #expect(await loop.stopCount >= 1)
        await controller.shutdown()
    }

    @Test("Teardown stops the receive loop before the gateway resets the media plane")
    func orderedTeardownStopsReceiveFirst() async throws {
        let recorder = ControllerReceiveOrderRecorder()
        let loop = ControllerReceiveLoopDouble(recorder: recorder)
        let factory = ControllerReceiveFactory(
            gateway: ControllerReceiveGateway(recorder: recorder),
            udp: ControllerReceiveUDP(recorder: recorder),
            receiveLoop: loop
        )
        let controller = try makeController(bridge: ControllerReceiveBridge(), factory: factory)
        _ = await controller.join(guildID: "g", channelID: "c")
        let snapshot = await controller.leave()
        #expect(!snapshot.receiveActive)
        #expect(await loop.stopCount == 1)
        let order = await recorder.snapshot()
        let receiveStop = order.firstIndex(of: "receiveStop")
        let gatewayDisconnect = order.firstIndex(of: "gatewayDisconnect")
        let udpDisconnect = order.firstIndex(of: "udpDisconnect")
        #expect(receiveStop != nil, "order was \(order)")
        #expect(gatewayDisconnect != nil, "order was \(order)")
        #expect(udpDisconnect != nil, "order was \(order)")
        if let receiveStop, let gatewayDisconnect, let udpDisconnect {
            #expect(receiveStop < gatewayDisconnect)
            #expect(gatewayDisconnect < udpDisconnect)
        }
    }

    @Test("A disable landing mid-enable is honored, not dropped")
    func disableDuringReceiveStartIsHonored() async throws {
        let loop = ControllerReceiveLoopDouble()
        let factory = ControllerReceiveFactory(
            gateway: ControllerReceiveGateway(),
            udp: ControllerReceiveUDP(),
            receiveLoop: loop
        )
        let controller = try makeController(bridge: ControllerReceiveBridge(), factory: factory)
        _ = await controller.join(guildID: "g", channelID: "c")

        // Park the controller inside `await receiveLoop.start(...)`, then ask
        // for silence from that window.
        await loop.gateNextStart()
        let enable = Task { await controller.setReceiveEnabled(true) }
        await loop.waitForStartEntry()
        let disable = Task { await controller.setReceiveEnabled(false) }
        await Task.yield()
        await loop.releaseStart()
        _ = await enable.value
        _ = await disable.value

        // The regression this pins: without a pending-desired-state loop the
        // disable hit the in-flight guard and vanished, and the resuming enable
        // then published an active receive — i.e. the bot kept decrypting
        // everyone's audio after the operator asked it to stop.
        let settled = await controller.currentSnapshot()
        #expect(!settled.receiveActive)
        #expect(await loop.stopCount >= 1)
        await controller.shutdown()
    }

    @Test("A receive-loop start failure fails closed while signaling stays up")
    func receiveStartFailureFailsClosed() async throws {
        let loop = ControllerReceiveLoopDouble()
        await loop.failNextStart()
        let factory = ControllerReceiveFactory(
            gateway: ControllerReceiveGateway(),
            udp: ControllerReceiveUDP(),
            receiveLoop: loop
        )
        let controller = try makeController(bridge: ControllerReceiveBridge(), factory: factory)
        _ = await controller.join(guildID: "g", channelID: "c")
        // The failure surfaces when the operator asks for receive, since that
        // is the only thing that starts the loop now.
        let snapshot = await controller.setReceiveEnabled(true)
        #expect(snapshot.phase == .readyMuted, "signaling must survive a receive failure")
        #expect(!snapshot.receiveActive)
        #expect(snapshot.failure == .receiveUnavailable)
        await controller.shutdown()
    }

    @Test("A terminal verdict after ready drops receive to inactive")
    func terminalAfterReadyFailsClosed() async throws {
        let loop = ControllerReceiveLoopDouble()
        let factory = ControllerReceiveFactory(
            gateway: ControllerReceiveGateway(),
            udp: ControllerReceiveUDP(),
            receiveLoop: loop
        )
        let controller = try makeController(bridge: ControllerReceiveBridge(), factory: factory)
        _ = await controller.join(guildID: "g", channelID: "c")
        // A terminal verdict only means anything once receive is running.
        _ = await controller.setReceiveEnabled(true)
        await loop.fireTerminal()
        let snapshot = await controller.currentSnapshot()
        #expect(!snapshot.receiveActive)
        #expect(snapshot.failure == .receiveUnavailable)
        #expect(snapshot.phase == .readyMuted, "signaling stays up")
        await controller.shutdown()
    }

    /// The reentrancy case the capture path was hardened for, mirrored: a
    /// terminal verdict that beats the controller's own `start` continuation
    /// must not be discarded, or the controller publishes an active receive over
    /// an already-dead loop.
    @Test("A terminal verdict landing mid-start is honored, not published over")
    func terminalDuringStartIsHonored() async throws {
        let loop = ControllerReceiveLoopDouble()
        let factory = ControllerReceiveFactory(
            gateway: ControllerReceiveGateway(),
            udp: ControllerReceiveUDP(),
            receiveLoop: loop
        )
        let controller = try makeController(bridge: ControllerReceiveBridge(), factory: factory)
        _ = await controller.join(guildID: "g", channelID: "c")
        // The start window now opens on the operator's explicit enable, not on
        // join — receive no longer starts implicitly.
        await loop.gateNextStart()

        let enable = Task { await controller.setReceiveEnabled(true) }
        await loop.waitForStartEntry()
        // The controller is suspended inside `await receiveLoop.start(...)`.
        await loop.fireTerminal()
        await loop.releaseStart()
        let snapshot = await enable.value

        #expect(!snapshot.receiveActive, "an already-failed loop must not read as active")
        #expect(snapshot.failure == .receiveUnavailable)
        #expect(await loop.stopCount == 1, "the failed loop is stopped, not left running")
        await controller.shutdown()
    }

    @Test("A failed join detaches and stops the receive loop")
    func failedJoinStopsReceiveLoop() async throws {
        let loop = ControllerReceiveLoopDouble()
        let factory = ControllerReceiveFactory(
            gateway: ControllerReceiveGateway(negotiates: false),
            udp: ControllerReceiveUDP(),
            receiveLoop: loop
        )
        let controller = try makeController(bridge: ControllerReceiveBridge(), factory: factory)
        let snapshot = await controller.join(guildID: "g", channelID: "c")
        #expect(snapshot.phase == .failed)
        #expect(snapshot.failure == .mediaUnavailable)
        #expect(!snapshot.receiveActive)
        // The loop was installed before negotiation failed, so teardown owns it.
        #expect(await loop.stopCount == 1)
        await controller.shutdown()
    }

    @Test("A rejoin does not silently resume receiving; it must be re-enabled")
    func rejoinRequiresReceiveToBeReEnabled() async throws {
        let loop = ControllerReceiveLoopDouble()
        let factory = ControllerReceiveFactory(
            gateway: ControllerReceiveGateway(),
            udp: ControllerReceiveUDP(),
            receiveLoop: loop
        )
        let controller = try makeController(bridge: ControllerReceiveBridge(), factory: factory)
        let first = await controller.join(guildID: "g", channelID: "c")
        _ = await controller.setReceiveEnabled(true)
        let second = await controller.join(guildID: "g", channelID: "c")
        #expect(second.generation > first.generation)
        // A privacy action is never inherited across generations: the new
        // session starts silent even though the previous one was receiving.
        #expect(!second.receiveActive)
        #expect(await loop.startGenerations == [first.generation])
        #expect(await loop.stopCount >= 1)

        // Re-enabling starts the loop for the NEW generation only.
        let resumed = await controller.setReceiveEnabled(true)
        #expect(resumed.receiveActive)
        #expect(await loop.startGenerations == [first.generation, second.generation])
        await controller.shutdown()
    }
}
