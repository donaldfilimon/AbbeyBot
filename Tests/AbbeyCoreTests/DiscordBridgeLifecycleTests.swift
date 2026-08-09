import DiscordBM
import Foundation
import Testing
@testable import AbbeyCore

private struct RecordedVoiceStateUpdate: Equatable, Sendable {
    let guildID: String
    let channelID: String?
}

private actor FakeDiscordGatewayDriver: DiscordGatewayDriver {
    nonisolated let client: (any DiscordClient)? = nil

    private let eventStream: AsyncStream<DiscordGatewayDriverEvent>
    private let eventContinuation: AsyncStream<DiscordGatewayDriverEvent>.Continuation
    private let failureStream: AsyncStream<Void>
    private let failureContinuation: AsyncStream<Void>.Continuation
    private let suspendsDisconnect: Bool
    private let disconnectStarted = DiscordGatewayEventBarrier()
    private let disconnectRelease = DiscordGatewayEventBarrier()
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var voiceUpdates: [RecordedVoiceStateUpdate] = []

    init(suspendsDisconnect: Bool = false) {
        let events = AsyncStream<DiscordGatewayDriverEvent>.makeStream()
        self.eventStream = events.stream
        self.eventContinuation = events.continuation
        let failures = AsyncStream<Void>.makeStream()
        self.failureStream = failures.stream
        self.failureContinuation = failures.continuation
        self.suspendsDisconnect = suspendsDisconnect
    }

    func makeEvents() async -> AsyncThrowingStream<DiscordGatewayDriverEvent, any Error> {
        DiscordGatewayEventStreamMerger.merge(events: eventStream, failures: failureStream)
    }

    func connect() async {
        connectCount += 1
    }

    func disconnect() async {
        disconnectCount += 1
        guard suspendsDisconnect else { return }
        await disconnectStarted.resolve()
        await disconnectRelease.wait()
    }

    func updateVoiceState(payload: VoiceStateUpdate) async {
        voiceUpdates.append(
            .init(
                guildID: payload.guild_id.rawValue,
                channelID: payload.channel_id?.rawValue
            )
        )
    }

    func emit(_ event: Gateway.Event) {
        eventContinuation.yield(.gateway(event))
    }

    func barrier() async {
        let barrier = DiscordGatewayEventBarrier()
        eventContinuation.yield(.barrier(barrier))
        await barrier.wait()
    }

    func finish() {
        eventContinuation.finish()
    }

    func fail() {
        failureContinuation.yield(())
        failureContinuation.finish()
    }

    func waitUntilDisconnectStarted() async {
        await disconnectStarted.wait()
    }

    func releaseDisconnect() async {
        await disconnectRelease.resolve()
    }

    func hasNullVoiceUpdate(count: Int) -> Bool {
        voiceUpdates.count == count && voiceUpdates.last?.channelID == nil
    }

    var nullVoiceUpdateCount: Int {
        voiceUpdates.count(where: { $0.channelID == nil })
    }
}

private actor FakeDiscordGatewayDriverFactory {
    private var drivers: [FakeDiscordGatewayDriver]
    private(set) var configurations: [DiscordGatewayDriverConfiguration] = []

    init(_ drivers: [FakeDiscordGatewayDriver]) {
        self.drivers = drivers
    }

    func make(
        _ configuration: DiscordGatewayDriverConfiguration
    ) -> any DiscordGatewayDriver {
        configurations.append(configuration)
        guard !drivers.isEmpty else {
            Issue.record("Fake gateway factory exhausted")
            return FakeDiscordGatewayDriver()
        }
        return drivers.removeFirst()
    }
}

private actor ReadyRecorder {
    private(set) var userIDs: [String] = []

    func record(_ userID: String) {
        userIDs.append(userID)
    }
}

private actor ConnectionOperationRecorder {
    private let connectStarted = DiscordGatewayEventBarrier()
    private let connectRelease = DiscordGatewayEventBarrier()
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var order: [String] = []

    func connect() async {
        connectCount += 1
        order.append("connect-start")
        await connectStarted.resolve()
        await connectRelease.wait()
        order.append("connect-finish")
    }

    func disconnect() {
        disconnectCount += 1
        order.append("disconnect")
    }

    func waitUntilConnectStarted() async {
        await connectStarted.wait()
    }

    func releaseConnect() async {
        await connectRelease.resolve()
    }
}

private actor ControlledVoiceSleeper {
    private var nextID: UInt64 = 0
    private var waiters: [(id: UInt64, barrier: DiscordGatewayEventBarrier)] = []
    private(set) var invocationCount = 0

    func sleep(for _: Duration) async throws {
        nextID &+= 1
        let id = nextID
        let barrier = DiscordGatewayEventBarrier()
        invocationCount += 1
        waiters.append((id: id, barrier: barrier))
        await withTaskCancellationHandler {
            await barrier.wait()
        } onCancel: {
            Task { await barrier.resolve() }
        }
        waiters.removeAll(where: { $0.id == id })
        try Task.checkCancellation()
    }

    func releaseNext() async {
        guard !waiters.isEmpty else {
            Issue.record("Expected a controlled sleeper waiter")
            return
        }
        let waiter = waiters.removeFirst()
        await waiter.barrier.resolve()
    }

    var waiterCount: Int { waiters.count }
}

private actor CollisionVoiceGatewaySession: DiscordVoiceGatewaySessionClient {
    func connect(
        using _: DiscordVoiceGatewayPair
    ) async throws -> DiscordVoiceGatewayTransportReady {
        .init(
            address: "127.0.0.1",
            port: 5_000,
            ssrc: 42,
            encryptionModes: ["aead_xchacha20_poly1305_rtpsize"]
        )
    }

    func selectTransport(_: DiscordVoiceDiscoveredEndpoint) async throws {}

    func negotiateDAVEAndMedia() async throws -> DiscordVoiceMediaCapabilities {
        .init(dave: true, aead: true, opus: true)
    }

    func disconnect() async {}
}

private actor CollisionVoiceUDPSession: DiscordVoiceUDPDiscoverySession {
    func discoverEndpoint(
        for _: DiscordVoiceGatewayTransportReady
    ) async throws -> DiscordVoiceDiscoveredEndpoint {
        .init(address: "127.0.0.1", port: 6_000)
    }

    func disconnect() async {}
}

private struct CollisionVoiceSessionFactory: DiscordVoiceSessionFactory {
    let mediaAdapterAvailability: DiscordVoiceMediaAdapterAvailability = .fullyWired
    let gateway = CollisionVoiceGatewaySession()
    let udp = CollisionVoiceUDPSession()

    func makeGatewayClient() -> any DiscordVoiceGatewaySessionClient { gateway }
    func makeUDPDiscoverySession() -> any DiscordVoiceUDPDiscoverySession { udp }
}

@Suite("Discord bridge injected Gateway lifecycle")
struct DiscordBridgeLifecycleTests {
    @Test("connection operations finish connect before one idempotent disconnect")
    func connectionOperationCoordinatorSerializesTeardown() async {
        let coordinator = DiscordConnectionOperationCoordinator()
        let recorder = ConnectionOperationRecorder()

        let connect = Task {
            await coordinator.connect { await recorder.connect() }
        }
        await recorder.waitUntilConnectStarted()
        #expect(await coordinator.phase == .connecting)

        let firstDisconnect = Task {
            await coordinator.disconnect { await recorder.disconnect() }
        }
        for _ in 0..<1_000 {
            if await coordinator.phase == .disconnecting { break }
            await Task.yield()
        }
        #expect(await coordinator.phase == .disconnecting)
        #expect(await recorder.disconnectCount == 0)

        let repeatedDisconnect = Task {
            await coordinator.disconnect { await recorder.disconnect() }
        }
        await recorder.releaseConnect()
        await connect.value
        await firstDisconnect.value
        await repeatedDisconnect.value

        #expect(await recorder.connectCount == 1)
        #expect(await recorder.disconnectCount == 1)
        #expect(await recorder.order == ["connect-start", "connect-finish", "disconnect"])
        #expect(await coordinator.phase == .disconnected)
        #expect(await coordinator.hasActiveOperation == false)

        await coordinator.disconnect { await recorder.disconnect() }
        #expect(await recorder.disconnectCount == 1)
        #expect(await coordinator.hasActiveOperation == false)
    }

    @Test("manager connect return is not READY and only current READY is authoritative")
    func readyAuthorityAndPinnedDisconnect() async throws {
        let staleDriver = FakeDiscordGatewayDriver()
        let currentDriver = FakeDiscordGatewayDriver()
        let factory = FakeDiscordGatewayDriverFactory([staleDriver, currentDriver])
        let recorder = ReadyRecorder()
        let bridge = makeBridge(factory: factory)
        let hooks = DiscordEventHooks(onReady: { await recorder.record($0) })

        await bridge.connect(token: "redacted-a", hooks: hooks)
        #expect(await staleDriver.connectCount == 1)
        #expect(await bridge.state == .connecting)
        #expect(await bridge.botUserId == nil)
        #expect(await recorder.userIDs.isEmpty)

        await staleDriver.emit(try readyEvent(userID: "100"))
        #expect(await eventually { await bridge.state == .connected })
        #expect(await bridge.botUserId == "100")
        #expect(await recorder.userIDs == ["100"])

        await bridge.connect(token: "redacted-b", hooks: hooks)
        #expect(await staleDriver.disconnectCount == 1)
        #expect(await currentDriver.connectCount == 1)
        #expect(await bridge.state == .connecting)
        #expect(await bridge.botUserId == nil)

        await staleDriver.emit(try readyEvent(userID: "999"))
        await currentDriver.barrier()
        #expect(await bridge.state == .connecting)
        #expect(await bridge.botUserId == nil)
        #expect(await recorder.userIDs == ["100"])

        await currentDriver.emit(try readyEvent(userID: "200"))
        #expect(await eventually { await bridge.state == .connected })
        #expect(await bridge.botUserId == "200")
        #expect(await recorder.userIDs == ["100", "200"])

        await bridge.disconnect()
        await bridge.disconnect()
        #expect(await currentDriver.disconnectCount == 1)
        #expect(await bridge.state == .disconnected)
        #expect(await bridge.hasGateway == false)
    }

    @Test("normal stream end and thrown stream failure fail only their current epoch")
    func streamCompletionAndFailure() async {
        let endingDriver = FakeDiscordGatewayDriver()
        let endingFactory = FakeDiscordGatewayDriverFactory([endingDriver])
        let endingBridge = makeBridge(factory: endingFactory)
        await endingBridge.connect(token: "redacted", hooks: .init())
        await endingDriver.finish()
        #expect(await eventually { await endingBridge.state == .failed })
        #expect(await endingBridge.lastError == DiscordGatewayLifecycle.streamEndedError)
        #expect(await endingDriver.disconnectCount == 1)
        #expect(await endingBridge.hasGateway == false)

        let failingDriver = FakeDiscordGatewayDriver()
        let failingFactory = FakeDiscordGatewayDriverFactory([failingDriver])
        let failingBridge = makeBridge(factory: failingFactory)
        await failingBridge.connect(token: "redacted", hooks: .init())
        await failingDriver.fail()
        #expect(await eventually { await failingBridge.state == .failed })
        #expect(await failingBridge.lastError == DiscordGatewayLifecycle.streamFailedError)
        #expect(await failingDriver.disconnectCount == 1)
        #expect(await failingBridge.hasGateway == false)
    }

    @Test("voice State then Server and Server then State produce only their generation")
    func voiceEventOrders() async throws {
        for serverFirst in [false, true] {
            let driver = FakeDiscordGatewayDriver()
            let factory = FakeDiscordGatewayDriverFactory([driver])
            let bridge = makeBridge(factory: factory)
            try await connectReady(bridge: bridge, driver: driver, userID: "42")

            guard case .requested(let generation) = await bridge.requestVoiceGatewayPair(
                guildId: "guild",
                channelId: "channel"
            ) else {
                Issue.record("Expected producer generation")
                continue
            }
            #expect(await bridge.voiceGuildId == nil)
            #expect(await bridge.voiceChannelId == nil)

            let state = try voiceStateEvent(
                guildID: "guild",
                channelID: "channel",
                userID: "42",
                sessionID: serverFirst ? "server-first-session" : "state-first-session"
            )
            let server = try voiceServerEvent(
                guildID: "guild",
                endpoint: "voice.example.invalid",
                token: "ephemeral-token"
            )
            if serverFirst {
                await driver.emit(server)
                await driver.barrier()
                #expect(await bridge.voiceGuildId == nil)
                #expect(await bridge.voiceChannelId == nil)
                #expect(await bridge.consumeVoiceGatewayCredentials(for: generation) == nil)
                await driver.emit(state)
            } else {
                await driver.emit(state)
                #expect(await eventually { await bridge.voiceChannelId == "channel" })
                #expect(await bridge.voiceGuildId == "guild")
                #expect(await bridge.consumeVoiceGatewayCredentials(for: generation) == nil)
                await driver.emit(server)
            }

            #expect(await eventually {
                await bridge.consumeVoiceGatewayCredentials(for: generation) != nil
            })
            #expect(await bridge.voiceGuildId == "guild")
            #expect(await bridge.voiceChannelId == "channel")
            try await acknowledgeLeave(
                bridge: bridge,
                driver: driver,
                guildID: "guild",
                userID: "42",
                sessionID: serverFirst ? "server-first-session" : "state-first-session"
            )
            await bridge.disconnect()
        }
    }

    @Test("wrong voice events and nil endpoint cannot publish presence or credentials")
    func rejectsMismatchedVoiceEvents() async throws {
        let driver = FakeDiscordGatewayDriver()
        let factory = FakeDiscordGatewayDriverFactory([driver])
        let bridge = makeBridge(factory: factory)
        try await connectReady(bridge: bridge, driver: driver, userID: "42")
        guard case .requested(let generation) = await bridge.requestVoiceGatewayPair(
            guildId: "guild",
            channelId: "channel"
        ) else {
            Issue.record("Expected producer generation")
            return
        }

        await driver.emit(try voiceStateEvent(
            guildID: "guild",
            channelID: "channel",
            userID: "wrong-user",
            sessionID: "wrong-user-session"
        ))
        await driver.emit(try voiceStateEvent(
            guildID: "guild",
            channelID: "wrong-channel",
            userID: "42",
            sessionID: "wrong-channel-session"
        ))
        await driver.emit(try voiceServerEvent(
            guildID: "wrong-guild",
            endpoint: "wrong.example.invalid",
            token: "wrong-token"
        ))
        await driver.emit(try voiceServerEvent(
            guildID: "guild",
            endpoint: nil,
            token: "invalidated-token"
        ))
        await driver.barrier()

        #expect(await bridge.voiceGuildId == nil)
        #expect(await bridge.voiceChannelId == nil)
        #expect(await bridge.consumeVoiceGatewayCredentials(for: generation) == nil)
        try await acknowledgeLeave(
            bridge: bridge,
            driver: driver,
            guildID: "guild",
            userID: "42",
            sessionID: "cleanup-session"
        )
        await bridge.disconnect()
    }

    @Test("matching self null state acknowledges leave and stale epoch cannot resurrect")
    func leaveAcknowledgementAndStaleEpoch() async throws {
        let oldDriver = FakeDiscordGatewayDriver()
        let currentDriver = FakeDiscordGatewayDriver()
        let factory = FakeDiscordGatewayDriverFactory([oldDriver, currentDriver])
        let bridge = makeBridge(factory: factory)
        try await connectReady(bridge: bridge, driver: oldDriver, userID: "42")
        guard case .requested(let generation) = await bridge.requestVoiceGatewayPair(
            guildId: "guild",
            channelId: "channel"
        ) else {
            Issue.record("Expected producer generation")
            return
        }
        await oldDriver.emit(try voiceStateEvent(
            guildID: "guild",
            channelID: "channel",
            userID: "42",
            sessionID: "session"
        ))
        await oldDriver.emit(try voiceServerEvent(
            guildID: "guild",
            endpoint: "voice.example.invalid",
            token: "ephemeral-token"
        ))
        #expect(await eventually {
            await bridge.consumeVoiceGatewayCredentials(for: generation) != nil
        })
        #expect(await bridge.voiceChannelId == "channel")

        let leave = Task {
            await bridge.leaveVoiceAndWaitForAcknowledgement(guildId: "guild")
        }
        #expect(await eventually {
            await oldDriver.hasNullVoiceUpdate(count: 2)
        })
        await oldDriver.emit(try voiceStateEvent(
            guildID: "guild",
            channelID: nil,
            userID: "42",
            sessionID: "session"
        ))
        #expect(await leave.value == .requested)
        #expect(await bridge.voiceGuildId == nil)
        #expect(await bridge.voiceChannelId == nil)

        await bridge.connect(token: "replacement", hooks: .init())
        await oldDriver.emit(try readyEvent(userID: "999"))
        await oldDriver.emit(try voiceStateEvent(
            guildID: "guild",
            channelID: "stale-channel",
            userID: "42",
            sessionID: "stale-session"
        ))
        await currentDriver.barrier()
        #expect(await bridge.state == .connecting)
        #expect(await bridge.botUserId == nil)
        #expect(await bridge.voiceChannelId == nil)

        await currentDriver.emit(try readyEvent(userID: "84"))
        #expect(await eventually { await bridge.state == .connected })
        #expect(await bridge.botUserId == "84")
        await bridge.disconnect()
    }

    @Test("controller and bridge deadline collision emits one leave before replacement")
    func controllerAndBridgeDeadlineCollision() async throws {
        let oldDriver = FakeDiscordGatewayDriver(suspendsDisconnect: true)
        let currentDriver = FakeDiscordGatewayDriver()
        let driverFactory = FakeDiscordGatewayDriverFactory([oldDriver, currentDriver])
        let bridgeSleeper = ControlledVoiceSleeper()
        let controllerSleeper = ControlledVoiceSleeper()
        let bridge = makeBridge(
            factory: driverFactory,
            sleeper: { try await bridgeSleeper.sleep(for: $0) }
        )
        try await connectReady(bridge: bridge, driver: oldDriver, userID: "42")

        let controller = try DiscordVoiceController(
            bridge: DiscordVoiceBridgeAdapter(bridge: bridge, pollInterval: .milliseconds(1)),
            factory: CollisionVoiceSessionFactory(),
            configuration: .init(credentialTimeout: .seconds(5)),
            sleeper: { try await controllerSleeper.sleep(for: $0) }
        )
        let firstJoin = Task {
            await controller.join(guildID: "guild", channelID: "old-channel")
        }

        #expect(await eventually {
            await oldDriver.voiceUpdates == [
                .init(guildID: "guild", channelID: "old-channel")
            ]
        })
        let firstGeneration = await controller.currentSnapshot().generation
        #expect(await eventually { await bridgeSleeper.waiterCount == 1 })
        #expect(await eventually { await controllerSleeper.waiterCount == 1 })

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await bridgeSleeper.releaseNext() }
            group.addTask { await controllerSleeper.releaseNext() }
        }

        #expect(await eventually { await oldDriver.nullVoiceUpdateCount == 1 })
        #expect(await eventually {
            let invocationCount = await bridgeSleeper.invocationCount
            let waiterCount = await bridgeSleeper.waiterCount
            return invocationCount == 2 && waiterCount == 1
        })
        #expect(await oldDriver.voiceUpdates.count == 2)

        let replacementJoin = Task {
            await controller.join(guildID: "guild", channelID: "new-channel")
        }
        #expect(await eventually {
            let snapshot = await controller.currentSnapshot()
            return snapshot.generation > firstGeneration
                && snapshot.phase == .requestingGatewayState
        })
        #expect(await oldDriver.voiceUpdates.count == 2)

        // Expire the old leave, but suspend its driver disconnect. The bridge
        // may establish a fresh Gateway epoch while the controller must remain
        // behind the old leave barrier.
        await bridgeSleeper.releaseNext()
        await oldDriver.waitUntilDisconnectStarted()
        #expect(await bridge.state == .disconnected)

        await bridge.connect(token: "replacement", hooks: .init())
        #expect(await currentDriver.connectCount == 1)
        await oldDriver.emit(try readyEvent(userID: "stale-user"))
        await oldDriver.emit(try voiceStateEvent(
            guildID: "guild",
            channelID: nil,
            userID: "42",
            sessionID: "stale-session"
        ))
        await currentDriver.barrier()
        #expect(await bridge.state == .connecting)
        #expect(await bridge.botUserId == nil)

        await currentDriver.emit(try readyEvent(userID: "84"))
        #expect(await eventually { await bridge.state == .connected })
        #expect(await currentDriver.voiceUpdates.isEmpty)
        #expect(await oldDriver.nullVoiceUpdateCount == 1)

        await oldDriver.releaseDisconnect()
        _ = await firstJoin.value
        #expect(await eventually {
            await currentDriver.voiceUpdates == [
                .init(guildID: "guild", channelID: "new-channel")
            ]
        })

        // Callbacks queued on the retired driver cannot cancel or resurrect
        // the accepted replacement generation.
        await oldDriver.emit(try readyEvent(userID: "stale-user-2"))
        await oldDriver.emit(try voiceStateEvent(
            guildID: "guild",
            channelID: nil,
            userID: "42",
            sessionID: "stale-session-2"
        ))
        await currentDriver.emit(try voiceStateEvent(
            guildID: "guild",
            channelID: "new-channel",
            userID: "84",
            sessionID: "replacement-session"
        ))
        await currentDriver.emit(try voiceServerEvent(
            guildID: "guild",
            endpoint: "voice.example.invalid",
            token: "replacement-ephemeral-token"
        ))
        let replacementSnapshot = await replacementJoin.value
        #expect(replacementSnapshot.phase == .readyMuted)
        #expect(replacementSnapshot.failure == nil)
        #expect(await bridge.state == .connected)
        #expect(await bridge.botUserId == "84")
        #expect(await bridge.voiceChannelId == "new-channel")
        #expect(await oldDriver.nullVoiceUpdateCount == 1)

        let cleanup = Task { await controller.leave() }
        #expect(await eventually { await currentDriver.nullVoiceUpdateCount == 1 })
        await currentDriver.emit(try voiceStateEvent(
            guildID: "guild",
            channelID: nil,
            userID: "84",
            sessionID: "replacement-session"
        ))
        _ = await cleanup.value
        await bridge.disconnect()
    }

    @Test("voice timeout closes the old Gateway epoch before replacement")
    func timeoutClosesOldEpoch() async throws {
        let oldDriver = FakeDiscordGatewayDriver()
        let currentDriver = FakeDiscordGatewayDriver()
        let factory = FakeDiscordGatewayDriverFactory([oldDriver, currentDriver])
        let bridge = makeBridge(factory: factory, sleeper: { _ in })
        try await connectReady(bridge: bridge, driver: oldDriver, userID: "42")

        _ = await bridge.requestVoiceGatewayPair(guildId: "guild", channelId: "channel")
        #expect(await eventually { await oldDriver.disconnectCount == 1 })
        #expect(await bridge.state == .disconnected)
        #expect(await bridge.hasGateway == false)

        await bridge.connect(token: "replacement", hooks: .init())
        #expect(await currentDriver.connectCount == 1)
        #expect(await bridge.state == .connecting)
        await oldDriver.emit(try readyEvent(userID: "999"))
        await currentDriver.barrier()
        #expect(await bridge.state == .connecting)
        #expect(await bridge.botUserId == nil)
        await currentDriver.emit(try readyEvent(userID: "84"))
        #expect(await eventually { await bridge.state == .connected })
        #expect(await bridge.botUserId == "84")
        await bridge.disconnect()
    }

    @Test("old suspended disconnect cannot clear a replacement READY epoch")
    func suspendedDisconnectCannotClearReplacement() async throws {
        let oldDriver = FakeDiscordGatewayDriver(suspendsDisconnect: true)
        let currentDriver = FakeDiscordGatewayDriver()
        let factory = FakeDiscordGatewayDriverFactory([oldDriver, currentDriver])
        let bridge = makeBridge(factory: factory)
        try await connectReady(bridge: bridge, driver: oldDriver, userID: "42")

        let oldTeardown = Task { await bridge.disconnect() }
        await oldDriver.waitUntilDisconnectStarted()
        #expect(await oldDriver.disconnectCount == 1)
        #expect(await bridge.state == .disconnected)
        #expect(await bridge.botUserId == nil)
        #expect(await bridge.hasGateway == false)

        let replacement = Task {
            await bridge.connect(token: "replacement", hooks: .init())
        }
        #expect(await eventually { await currentDriver.connectCount == 1 })
        await currentDriver.emit(try readyEvent(userID: "84"))
        #expect(await eventually { await bridge.state == .connected })
        #expect(await bridge.botUserId == "84")
        #expect(await bridge.hasGateway)

        await oldDriver.releaseDisconnect()
        await oldTeardown.value
        await replacement.value
        #expect(await bridge.state == .connected)
        #expect(await bridge.botUserId == "84")
        #expect(await bridge.hasGateway)
        #expect(await oldDriver.disconnectCount == 1)

        await bridge.disconnect()
        #expect(await currentDriver.disconnectCount == 1)
        #expect(await oldDriver.disconnectCount == 1)
    }

    @Test("suspended stream teardown cannot resolve or clear a replacement epoch")
    func suspendedStreamTeardownCannotClearReplacement() async throws {
        let oldDriver = FakeDiscordGatewayDriver(suspendsDisconnect: true)
        let currentDriver = FakeDiscordGatewayDriver()
        let factory = FakeDiscordGatewayDriverFactory([oldDriver, currentDriver])
        let bridge = makeBridge(factory: factory)
        try await connectReady(bridge: bridge, driver: oldDriver, userID: "42")

        await oldDriver.finish()
        await oldDriver.waitUntilDisconnectStarted()
        #expect(await bridge.state == .failed)
        #expect(await bridge.hasGateway == false)

        let replacement = Task {
            await bridge.connect(token: "replacement", hooks: .init())
        }
        #expect(await eventually { await currentDriver.connectCount == 1 })
        await currentDriver.emit(try readyEvent(userID: "84"))
        #expect(await eventually { await bridge.state == .connected })

        await oldDriver.releaseDisconnect()
        await replacement.value
        #expect(await bridge.state == .connected)
        #expect(await bridge.botUserId == "84")
        #expect(await bridge.hasGateway)
        #expect(await oldDriver.disconnectCount == 1)

        await bridge.disconnect()
        #expect(await currentDriver.disconnectCount == 1)
        #expect(await oldDriver.disconnectCount == 1)
    }

    private func makeBridge(
        factory: FakeDiscordGatewayDriverFactory,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) -> DiscordBridge {
        DiscordBridge(
            voiceHandshakeTimeout: .seconds(5),
            voiceHandshakeSleep: sleeper,
            gatewayFactory: { await factory.make($0) }
        )
    }

    private func connectReady(
        bridge: DiscordBridge,
        driver: FakeDiscordGatewayDriver,
        userID: String
    ) async throws {
        await bridge.connect(token: "redacted", hooks: .init())
        #expect(await bridge.state == .connecting)
        await driver.emit(try readyEvent(userID: userID))
        #expect(await eventually { await bridge.state == .connected })
    }

    private func acknowledgeLeave(
        bridge: DiscordBridge,
        driver: FakeDiscordGatewayDriver,
        guildID: String,
        userID: String,
        sessionID: String
    ) async throws {
        let expectedUpdateCount = await driver.voiceUpdates.count + 1
        let leave = Task {
            await bridge.leaveVoiceAndWaitForAcknowledgement(guildId: guildID)
        }
        #expect(await eventually {
            await driver.hasNullVoiceUpdate(count: expectedUpdateCount)
        })
        await driver.emit(try voiceStateEvent(
            guildID: guildID,
            channelID: nil,
            userID: userID,
            sessionID: sessionID
        ))
        #expect(await leave.value == .requested)
    }

    private func eventually(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return false
    }

    private func readyEvent(userID: String) throws -> Gateway.Event {
        let json = """
        {
          "op": 0,
          "s": 1,
          "t": "READY",
          "d": {
            "v": 10,
            "user": {
              "id": "\(userID)",
              "username": "abbey",
              "discriminator": "0000"
            },
            "guilds": [],
            "session_id": "gateway-session-\(userID)",
            "resume_gateway_url": "wss://gateway.example.invalid",
            "application": { "id": "999" }
          }
        }
        """
        return try JSONDecoder().decode(Gateway.Event.self, from: Data(json.utf8))
    }

    private func voiceStateEvent(
        guildID: String,
        channelID: String?,
        userID: String,
        sessionID: String
    ) throws -> Gateway.Event {
        let channel = channelID.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "guild_id": "\(guildID)",
          "channel_id": \(channel),
          "user_id": "\(userID)",
          "session_id": "\(sessionID)",
          "deaf": false,
          "mute": false,
          "self_deaf": true,
          "self_mute": true,
          "self_video": false,
          "suppress": false
        }
        """
        let payload = try JSONDecoder().decode(VoiceState.self, from: Data(json.utf8))
        return .init(
            opcode: .dispatch,
            data: .voiceStateUpdate(payload),
            sequenceNumber: 2,
            type: "VOICE_STATE_UPDATE"
        )
    }

    private func voiceServerEvent(
        guildID: String,
        endpoint: String?,
        token: String
    ) throws -> Gateway.Event {
        let endpointJSON = endpoint.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "token": "\(token)",
          "guild_id": "\(guildID)",
          "endpoint": \(endpointJSON)
        }
        """
        let payload = try JSONDecoder().decode(
            Gateway.VoiceServerUpdate.self,
            from: Data(json.utf8)
        )
        return .init(
            opcode: .dispatch,
            data: .voiceServerUpdate(payload),
            sequenceNumber: 3,
            type: "VOICE_SERVER_UPDATE"
        )
    }
}
