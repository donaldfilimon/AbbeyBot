import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import AbbeyCore

@Suite("Discord Voice persistent UDP session", .serialized)
struct DiscordVoiceUDPSessionTests {
    @Test("Discovery and protected media share one socket and source port")
    func discoveryAndMediaShareSocket() async throws {
        let ssrc: UInt32 = 0xCAFE_BABE
        let server = try await PersistentUDPTestServer.start(
            discoverySSRC: ssrc,
            mediaReply: [0x90, 0x91, 0x92]
        )
        defer { server.stopEventually() }
        let session = makeSession(serverPort: server.port)

        try await session.open()
        let discovery = try await session.discover(ssrc: ssrc)
        #expect(discovery.address == "127.0.0.1")
        #expect(discovery.port != 0)

        try await session.sendProtectedPacket([0x80, 0x78, 0x01, 0x02])
        await server.observation.waitForMediaCount(1)
        let reply = try await session.receiveProtectedPacket()

        #expect(reply == [0x90, 0x91, 0x92])
        let ports = await server.observation.observedSourcePorts()
        #expect(ports.discovery != nil)
        #expect(ports.discovery == ports.media.first)
        #expect(discovery.port == UInt16(ports.discovery ?? 0))
        #expect(await session.snapshot().state == .ready)

        await session.close()
        await server.stop()
    }

    @Test("Only the configured remote is accepted and buffers stay bounded")
    func remoteFilteringAndBounds() async throws {
        let ssrc: UInt32 = 42
        let server = try await PersistentUDPTestServer.start(discoverySSRC: ssrc)
        defer { server.stopEventually() }
        let session = DiscordVoiceUDPSession(
            configuration: .init(
                serverAddress: "127.0.0.1",
                serverPort: server.port,
                discoveryTimeout: .seconds(2),
                maximumDatagramBytes: 128,
                maximumBufferedDatagrams: 2
            )
        )

        try await session.open()
        _ = try await session.discover(ssrc: ssrc)

        await expectSessionError(.invalidDatagramSize) {
            try await session.sendProtectedPacket([])
        }
        await expectSessionError(.invalidDatagramSize) {
            try await session.sendProtectedPacket([UInt8](repeating: 1, count: 129))
        }

        try await server.sendFromForeignSocket([0xFA])
        try await Task.sleep(for: .milliseconds(25))
        try await server.sendFromConfiguredSocket([0xA1])
        #expect(try await session.receiveProtectedPacket() == [0xA1])

        try await server.sendFromConfiguredSocket([UInt8](repeating: 0xEE, count: 129))
        try await server.sendFromConfiguredSocket([0xB1])
        let afterOversized = try await session.receiveProtectedPacket()
        #expect(afterOversized == [0xB1])

        try await server.sendFromConfiguredSocket([0xC1])
        try await server.sendFromConfiguredSocket([0xC2])
        try await server.sendFromConfiguredSocket([0xC3])
        try await waitUntil {
            let snapshot = await session.snapshot()
            return snapshot.queuedDatagrams == 2 && snapshot.droppedDatagrams >= 2
        }
        let snapshot = await session.snapshot()
        #expect(snapshot.queuedDatagrams == 2)
        #expect(snapshot.droppedDatagrams >= 2)
        #expect(!snapshot.description.contains("127.0.0.1"))

        await session.close()
        await server.stop()
    }

    @Test("Discovery deadline preserves the socket for an explicit close")
    func discoveryTimeoutAndTeardown() async throws {
        let server = try await PersistentUDPTestServer.start(
            discoverySSRC: 7,
            respondToDiscovery: false
        )
        defer { server.stopEventually() }
        let session = DiscordVoiceUDPSession(
            configuration: .init(
                serverAddress: "127.0.0.1",
                serverPort: server.port,
                discoveryTimeout: .milliseconds(50)
            )
        )

        try await session.open()
        await expectDiscoveryError(.timeout) {
            try await session.discover(ssrc: 7)
        }
        #expect(await session.snapshot().state == .open)

        await session.close()
        await session.close()
        #expect(await session.snapshot().state == .closed)
        await expectSessionError(.closed) {
            try await session.sendProtectedPacket([1])
        }
        await server.stop()
    }

    @Test("Cancelling discovery and receive clears waiters and closes cleanly")
    func cancellationSafety() async throws {
        let ssrc: UInt32 = 19
        let server = try await PersistentUDPTestServer.start(
            discoverySSRC: ssrc,
            respondToDiscovery: false
        )
        defer { server.stopEventually() }
        let session = makeSession(serverPort: server.port, timeout: .seconds(30))

        try await session.open()
        let discovery = Task { try await session.discover(ssrc: ssrc) }
        await server.observation.waitForDiscovery()
        discovery.cancel()
        await expectCancellation { _ = try await discovery.value }
        #expect(await session.snapshot().state == .open)

        await server.setRespondToDiscovery(true)
        _ = try await session.discover(ssrc: ssrc)

        let receive = Task { try await session.receiveProtectedPacket() }
        try await Task.sleep(for: .milliseconds(20))
        receive.cancel()
        await expectCancellation { _ = try await receive.value }

        try await server.sendFromConfiguredSocket([0xD1])
        #expect(try await session.receiveProtectedPacket() == [0xD1])

        await session.close()
        await server.stop()
    }

    @Test("Calls before open and invalid configurations fail without binding")
    func lifecycleValidation() async throws {
        let unopened = DiscordVoiceUDPSession(
            configuration: .init(serverAddress: "127.0.0.1", serverPort: 9)
        )
        await expectSessionError(.notOpen) {
            try await unopened.sendProtectedPacket([1])
        }
        await expectSessionError(.notOpen) {
            _ = try await unopened.receiveProtectedPacket()
        }
        await unopened.close()

        let invalid = DiscordVoiceUDPSession(
            configuration: .init(serverAddress: "not-an-ip", serverPort: 0)
        )
        await expectSessionError(.invalidConfiguration) {
            try await invalid.open()
        }
        #expect(await invalid.snapshot().state == .idle)
        await invalid.close()
    }

    @Test("A second open is rejected while the first bind is awaiting adoption")
    func concurrentOpenIsRejected() async throws {
        let server = try await PersistentUDPTestServer.start(discoverySSRC: 51)
        defer { server.stopEventually() }
        let gate = PersistentUDPAsyncGate()
        let session = DiscordVoiceUDPSession(
            configuration: .init(
                serverAddress: "127.0.0.1",
                serverPort: server.port
            ),
            didBindHook: { await gate.enterAndWait() }
        )

        let firstOpen = Task { try await session.open() }
        await gate.waitUntilEntered()
        #expect(await session.snapshot().state == .opening)
        await expectSessionError(.alreadyOpen) {
            try await session.open()
        }

        await gate.release()
        try await firstOpen.value
        #expect(await session.snapshot().state == .open)
        await session.close()
        await server.stop()
    }

    @Test("Close invalidates a bound channel before it can be adopted")
    func closeDuringOpenCannotResurrectSession() async throws {
        let server = try await PersistentUDPTestServer.start(discoverySSRC: 52)
        defer { server.stopEventually() }
        let gate = PersistentUDPAsyncGate()
        let session = DiscordVoiceUDPSession(
            configuration: .init(
                serverAddress: "127.0.0.1",
                serverPort: server.port
            ),
            didBindHook: { await gate.enterAndWait() }
        )

        let opening = Task { try await session.open() }
        await gate.waitUntilEntered()
        await session.close()
        await gate.release()

        await expectSessionError(.closed) {
            try await opening.value
        }
        #expect(await session.snapshot().state == .closed)
        await expectSessionError(.closed) {
            try await session.open()
        }
        await server.stop()
    }

    @Test("A pre-cancelled receive does not consume a buffered datagram")
    func preCancelledBufferedReceivePreservesPacket() async throws {
        let ssrc: UInt32 = 53
        let server = try await PersistentUDPTestServer.start(discoverySSRC: ssrc)
        defer { server.stopEventually() }
        let session = makeSession(serverPort: server.port)

        try await session.open()
        _ = try await session.discover(ssrc: ssrc)
        try await server.sendFromConfiguredSocket([0xE1])
        try await waitUntil { await session.snapshot().queuedDatagrams == 1 }

        let cancelledReceive = Task { () throws -> [UInt8] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await session.receiveProtectedPacket()
        }
        await expectCancellation { _ = try await cancelledReceive.value }
        #expect(await session.snapshot().queuedDatagrams == 1)
        #expect(try await session.receiveProtectedPacket() == [0xE1])

        await session.close()
        await server.stop()
    }

    @Test("Cancellation wins delivery races without leaving a stuck waiter")
    func cancellationDeliveryRace() async throws {
        let ssrc: UInt32 = 54
        let server = try await PersistentUDPTestServer.start(discoverySSRC: ssrc)
        defer { server.stopEventually() }

        for iteration in 0..<32 {
            let session = makeSession(serverPort: server.port)
            try await session.open()
            _ = try await session.discover(ssrc: ssrc)
            let receive = Task { try await session.receiveProtectedPacket() }
            try await waitUntil { await session.hasPendingReceiveWaiterForTesting() }
            let racedPacket = [0xF0, UInt8(iteration)]

            async let cancellation: Void = {
                receive.cancel()
            }()
            async let delivery: Void = server.sendFromConfiguredSocket(racedPacket)
            _ = try await (cancellation, delivery)

            // Either outcome is correct, and which one wins is genuinely
            // racy. If the cancel lands first the receive throws; if the
            // datagram resumes the waiter first the receive returns that
            // packet, and delivering it is right — an arrived datagram is not
            // discarded just because a cancel was in flight. Asserting that
            // cancellation ALWAYS wins made this test fail roughly one run in
            // thirty-two iterations for a system behaving correctly.
            //
            // The invariant this test exists for is the other half of its
            // name: whoever wins, no waiter is left stuck.
            do {
                let delivered = try await receive.value
                #expect(delivered == racedPacket)
            } catch {
                #expect(error is CancellationError)
            }
            #expect(!(await session.hasPendingReceiveWaiterForTesting()))
            await session.close()
        }

        await server.stop()
    }

    @Test("A dropped discovery response times out and a caller retry reuses the same socket")
    func discoveryLossRetryReusesSocket() async throws {
        let ssrc: UInt32 = 61
        let server = try await PersistentUDPTestServer.start(
            discoverySSRC: ssrc,
            respondToDiscovery: false
        )
        defer { server.stopEventually() }
        let session = makeSession(serverPort: server.port)

        try await session.open()
        // Induced loss: the server receives the request and drops the response. The session
        // performs no in-call retransmit; it fails closed on the deadline and returns to .open.
        let firstDeadline = ContinuousClock().now.advanced(by: .milliseconds(100))
        await expectDiscoveryError(.timeout) {
            try await session.discover(ssrc: ssrc, deadline: firstDeadline)
        }
        #expect(await session.snapshot().state == .open)
        await server.observation.waitForDiscovery()
        let portAfterLoss = await server.observation.observedSourcePorts().discovery

        // Caller-driven retry must reuse the identical socket: the NAT mapping Discord reports
        // belongs to this source port, so a rebind would invalidate the discovery result.
        await server.setRespondToDiscovery(true)
        let discovery = try await session.discover(ssrc: ssrc)
        #expect(portAfterLoss != nil)
        #expect(discovery.port == UInt16(portAfterLoss ?? 0))
        #expect(await session.snapshot().state == .ready)

        await session.close()
        await server.stop()
    }

    @Test("Truncated and SSRC-corrupted discovery responses fail closed and keep the socket")
    func discoveryCorruptionFailsClosed() async throws {
        let ssrc: UInt32 = 62
        let server = try await PersistentUDPTestServer.start(
            discoverySSRC: ssrc,
            respondToDiscovery: false
        )
        defer { server.stopEventually() }
        let session = makeSession(serverPort: server.port)

        try await session.open()
        // This first, deliberately dropped attempt teaches the server the client's address so
        // fault datagrams can be injected from the configured remote below.
        let firstDeadline = ContinuousClock().now.advanced(by: .milliseconds(100))
        await expectDiscoveryError(.timeout) {
            try await session.discover(ssrc: ssrc, deadline: firstDeadline)
        }

        // Truncation: one byte short of the fixed 74-byte packet is rejected outright.
        let truncated = Array(
            makePersistentDiscoveryResponse(ssrc: ssrc, observedPort: 50_000).dropLast()
        )
        try await server.sendFromConfiguredSocket(truncated)
        try await waitUntil { await session.snapshot().queuedDatagrams == 1 }
        await expectDiscoveryError(.invalidPacketSize) {
            try await session.discover(ssrc: ssrc)
        }
        #expect(await session.snapshot().state == .open)

        // Corruption: a well-formed response for the wrong SSRC is rejected, not adopted.
        try await server.sendFromConfiguredSocket(
            makePersistentDiscoveryResponse(ssrc: ssrc &+ 1, observedPort: 50_000)
        )
        try await waitUntil { await session.snapshot().queuedDatagrams == 1 }
        await expectDiscoveryError(.ssrcMismatch) {
            try await session.discover(ssrc: ssrc)
        }
        #expect(await session.snapshot().state == .open)

        // The preserved socket still completes discovery once an intact response arrives.
        await server.setRespondToDiscovery(true)
        _ = try await session.discover(ssrc: ssrc)
        #expect(await session.snapshot().state == .ready)

        await session.close()
        await server.stop()
    }

    @Test("Duplicated and reordered datagrams are delivered exactly as received")
    func duplicatedAndReorderedReceivePath() async throws {
        let ssrc: UInt32 = 63
        let server = try await PersistentUDPTestServer.start(discoverySSRC: ssrc)
        defer { server.stopEventually() }
        let session = makeSession(serverPort: server.port)

        try await session.open()
        _ = try await session.discover(ssrc: ssrc)

        // The UDP session must not mask network reordering or duplication: RTP sequence numbers
        // and SRTP replay protection above this layer own dedupe/reorder, so delivery order must
        // equal arrival order with duplicates intact.
        let arrivalOrder: [[UInt8]] = [
            [0x80, 0x02], // second packet arrives first
            [0x80, 0x01], // first packet arrives late
            [0x80, 0x01], // then a duplicate of it
            [0x80, 0x03],
        ]
        for datagram in arrivalOrder {
            try await server.sendFromConfiguredSocket(datagram)
        }
        var delivered: [[UInt8]] = []
        for _ in arrivalOrder {
            delivered.append(try await session.receiveProtectedPacket())
        }
        #expect(delivered == arrivalOrder)

        // A duplicated discovery response arriving after readiness is opaque media-path bytes;
        // rejecting it belongs to the RTP/crypto layer, and it must not disturb session state.
        let lateDiscovery = makePersistentDiscoveryResponse(ssrc: ssrc, observedPort: 50_000)
        try await server.sendFromConfiguredSocket(lateDiscovery)
        #expect(try await session.receiveProtectedPacket() == lateDiscovery)
        #expect(await session.snapshot().state == .ready)

        await session.close()
        await server.stop()
    }

    private func makeSession(
        serverPort: Int,
        timeout: Duration = .seconds(2)
    ) -> DiscordVoiceUDPSession {
        DiscordVoiceUDPSession(
            configuration: .init(
                serverAddress: "127.0.0.1",
                serverPort: serverPort,
                discoveryTimeout: timeout
            )
        )
    }

    private func expectSessionError<T: Sendable>(
        _ expected: DiscordVoiceUDPSession.SessionError,
        operation: @escaping @Sendable () async throws -> T
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected UDP session error \(expected)")
        } catch let error as DiscordVoiceUDPSession.SessionError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected UDP session error type")
        }
    }

    private func expectDiscoveryError(
        _ expected: DiscordVoiceUDPDiscoveryError,
        operation: @escaping @Sendable () async throws -> DiscordVoiceUDPDiscoveryResult
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected discovery error \(expected)")
        } catch let error as DiscordVoiceUDPDiscoveryError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected discovery error type")
        }
    }

    private func expectCancellation(
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for UDP session condition")
    }
}

private func makePersistentDiscoveryResponse(
    ssrc: UInt32,
    observedPort: UInt16
) -> [UInt8] {
    var response = [UInt8](repeating: 0, count: DiscordVoiceUDPDiscoveryCodec.packetSize)
    response[0] = 0
    response[1] = 2
    response[2] = 0
    response[3] = 70
    response[4] = UInt8(truncatingIfNeeded: ssrc >> 24)
    response[5] = UInt8(truncatingIfNeeded: ssrc >> 16)
    response[6] = UInt8(truncatingIfNeeded: ssrc >> 8)
    response[7] = UInt8(truncatingIfNeeded: ssrc)
    response.replaceSubrange(8..<17, with: Array("127.0.0.1".utf8))
    response[72] = UInt8(truncatingIfNeeded: observedPort >> 8)
    response[73] = UInt8(truncatingIfNeeded: observedPort)
    return response
}

private actor PersistentUDPObservation {
    private var discoveryPort: Int?
    private var mediaPorts: [Int] = []
    private var mediaPackets: [[UInt8]] = []
    private var clientAddress: SocketAddress?
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var mediaWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func recordDiscovery(from address: SocketAddress) {
        discoveryPort = address.port
        clientAddress = address
        let waiters = discoveryWaiters
        discoveryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func recordMedia(_ bytes: [UInt8], from address: SocketAddress) {
        clientAddress = address
        if let port = address.port { mediaPorts.append(port) }
        mediaPackets.append(bytes)
        let ready = mediaWaiters.filter { mediaPackets.count >= $0.count }
        mediaWaiters.removeAll { mediaPackets.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForDiscovery() async {
        if discoveryPort != nil { return }
        await withCheckedContinuation { discoveryWaiters.append($0) }
    }

    func waitForMediaCount(_ count: Int) async {
        if mediaPackets.count >= count { return }
        await withCheckedContinuation { mediaWaiters.append((count, $0)) }
    }

    func observedSourcePorts() -> (discovery: Int?, media: [Int]) {
        (discoveryPort, mediaPorts)
    }

    func lastClientAddress() -> SocketAddress? {
        clientAddress
    }
}

private actor PersistentUDPServerControl {
    private var respondToDiscovery: Bool

    init(respondToDiscovery: Bool) {
        self.respondToDiscovery = respondToDiscovery
    }

    func shouldRespondToDiscovery() -> Bool {
        respondToDiscovery
    }

    func setRespondToDiscovery(_ value: Bool) {
        respondToDiscovery = value
    }
}

private final class PersistentUDPTestServer: @unchecked Sendable {
    let port: Int
    let observation: PersistentUDPObservation

    private let discoverySSRC: UInt32
    private let mediaReply: [UInt8]?
    private let control: PersistentUDPServerControl
    private let group: MultiThreadedEventLoopGroup
    private let channel: NIOAsyncChannel<
        AddressedEnvelope<ByteBuffer>,
        AddressedEnvelope<ByteBuffer>
    >
    private let stopGate = PersistentUDPStopGate()
    private var task: Task<Void, Never>?

    private init(
        port: Int,
        discoverySSRC: UInt32,
        mediaReply: [UInt8]?,
        respondToDiscovery: Bool,
        group: MultiThreadedEventLoopGroup,
        channel: NIOAsyncChannel<
            AddressedEnvelope<ByteBuffer>,
            AddressedEnvelope<ByteBuffer>
        >
    ) {
        self.port = port
        self.discoverySSRC = discoverySSRC
        self.mediaReply = mediaReply
        self.control = PersistentUDPServerControl(respondToDiscovery: respondToDiscovery)
        self.group = group
        self.channel = channel
        self.observation = PersistentUDPObservation()
    }

    static func start(
        discoverySSRC: UInt32,
        respondToDiscovery: Bool = true,
        mediaReply: [UInt8]? = nil
    ) async throws -> PersistentUDPTestServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await DatagramBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<
                            AddressedEnvelope<ByteBuffer>,
                            AddressedEnvelope<ByteBuffer>
                        >(
                            wrappingChannelSynchronously: channel,
                            configuration: .init(
                                backPressureStrategy: .init(lowWatermark: 1, highWatermark: 2)
                            )
                        )
                    }
                }
            guard let port = channel.channel.localAddress?.port else {
                try await channel.channel.close()
                try await group.shutdownGracefully()
                throw DiscordVoiceUDPSession.SessionError.transportFailure
            }
            let server = PersistentUDPTestServer(
                port: port,
                discoverySSRC: discoverySSRC,
                mediaReply: mediaReply,
                respondToDiscovery: respondToDiscovery,
                group: group,
                channel: channel
            )
            server.startReceiving()
            return server
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func startReceiving() {
        task = Task { [channel, control, discoverySSRC, mediaReply, observation] in
            do {
                try await channel.executeThenClose { inbound, outbound in
                    for try await envelope in inbound {
                        let bytes = envelope.data.getBytes(
                            at: envelope.data.readerIndex,
                            length: envelope.data.readableBytes
                        ) ?? []
                        if bytes == DiscordVoiceUDPDiscoveryCodec.encodeRequest(ssrc: discoverySSRC) {
                            await observation.recordDiscovery(from: envelope.remoteAddress)
                            guard await control.shouldRespondToDiscovery(),
                                  let observedPort = envelope.remoteAddress.port,
                                  let port = UInt16(exactly: observedPort)
                            else { continue }
                            let response = makePersistentDiscoveryResponse(
                                ssrc: discoverySSRC,
                                observedPort: port
                            )
                            var buffer = channel.channel.allocator.buffer(capacity: response.count)
                            buffer.writeBytes(response)
                            try await outbound.write(
                                AddressedEnvelope(
                                    remoteAddress: envelope.remoteAddress,
                                    data: buffer
                                )
                            )
                        } else {
                            await observation.recordMedia(bytes, from: envelope.remoteAddress)
                            if let mediaReply {
                                var buffer = channel.channel.allocator.buffer(
                                    capacity: mediaReply.count
                                )
                                buffer.writeBytes(mediaReply)
                                try await outbound.write(
                                    AddressedEnvelope(
                                        remoteAddress: envelope.remoteAddress,
                                        data: buffer
                                    )
                                )
                            }
                        }
                    }
                }
            } catch {
                // Cancellation and channel close are expected teardown paths in these tests.
            }
        }
    }

    func setRespondToDiscovery(_ value: Bool) async {
        await control.setRespondToDiscovery(value)
    }

    func sendFromConfiguredSocket(_ bytes: [UInt8]) async throws {
        guard let client = await observation.lastClientAddress() else {
            throw DiscordVoiceUDPSession.SessionError.transportFailure
        }
        var buffer = channel.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.channel.writeAndFlush(
            AddressedEnvelope(remoteAddress: client, data: buffer)
        )
    }

    func sendFromForeignSocket(_ bytes: [UInt8]) async throws {
        guard let client = await observation.lastClientAddress() else {
            throw DiscordVoiceUDPSession.SessionError.transportFailure
        }
        let foreignGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let foreign = try await DatagramBootstrap(group: foreignGroup)
                .bind(host: "127.0.0.1", port: 0)
                .get()
            var buffer = foreign.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            try await foreign.writeAndFlush(
                AddressedEnvelope(remoteAddress: client, data: buffer)
            )
            try await foreign.close()
            try await foreignGroup.shutdownGracefully()
        } catch {
            try? await foreignGroup.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        guard await stopGate.beginStop() else { return }
        task?.cancel()
        try? await channel.channel.close()
        _ = await task?.result
        try? await group.shutdownGracefully()
        task = nil
    }

    func stopEventually() {
        Task { await stop() }
    }
}

private actor PersistentUDPStopGate {
    private var stopped = false

    func beginStop() -> Bool {
        guard !stopped else { return false }
        stopped = true
        return true
    }
}

private actor PersistentUDPAsyncGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
