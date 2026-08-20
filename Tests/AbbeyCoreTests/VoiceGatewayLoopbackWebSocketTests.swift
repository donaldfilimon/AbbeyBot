import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Testing
import WSClient
@testable import AbbeyCore

/// Closes the "scripted local Voice WebSocket server" gap noted in `tasks/todo.md`'s voice
/// audit: every other Voice Gateway v8 test drives `VoiceGatewayClient` through an in-process
/// fake `VoiceGatewayClientTransport` (see `VoiceGatewayClientTests.swift`). These tests instead
/// bind a real `NIOTypedWebSocketServerUpgrader`-based WebSocket server to `127.0.0.1:0` and
/// connect to it with the same `WSClient.WebSocketClient` production uses, so the client-side
/// state machine's Identify → Ready → Session Description handshake, close-code handling, and
/// heartbeat-ACK timeout are proven over a genuine WebSocket handshake and real frame
/// (de)serialization instead of an injected fake.
///
/// Scope: this is the WebSocket transport layer only. Codec/crypto/DAVE payload correctness and
/// audio-device fault injection are explicitly out of scope here — see
/// `VoiceGatewayDAVETests.swift`/`VoiceGatewayV8ModelsTests.swift` for those, and `tasks/todo.md`
/// for what remains open.
@Suite("Discord Voice Gateway real WebSocket loopback")
struct VoiceGatewayLoopbackWebSocketTests {
    @Test func identifyReadySessionDescriptionHandshakeReachesEstablishedOverRealSocket() async throws {
        let server = try await VoiceGatewayLoopbackServer.start()
        defer { server.stopEventually() }

        let client = try makeLoopbackClient(
            port: server.port,
            configuration: .init(maximumReconnectAttempts: 0)
        )
        let connectionTask = Task { await server.nextConnection() }
        let outcomeTask = Task { try await client.connect() }

        guard let connection = await connectionTask.value else {
            Issue.record("Expected the client to complete a real WebSocket handshake")
            return
        }

        await connection.sendHello(heartbeatIntervalMilliseconds: 10_000)

        guard case .text(let identifyText) = await connection.receiveEvent() else {
            Issue.record("Expected an Identify frame over the real socket")
            return
        }
        #expect(opcode(of: identifyText) == VoiceGatewayV8Identify.opcode)
        #expect(stringField(of: identifyText, key: "server_id") == "guild")

        await connection.sendReady(
            ssrc: 44,
            ip: "203.0.113.8",
            port: 50_000,
            modes: ["aead_xchacha20_poly1305_rtpsize"],
            sequence: 12
        )

        guard case .text(let selectProtocolText) = await connection.receiveEvent() else {
            Issue.record("Expected a Select Protocol frame over the real socket")
            return
        }
        #expect(opcode(of: selectProtocolText) == VoiceGatewayV8SelectProtocol.opcode)

        await connection.sendSessionDescription(mode: "aead_xchacha20_poly1305_rtpsize", sequence: 13)
        try await eventually { await client.snapshot().phase == .established }

        await connection.closeConnection(code: 1000, reason: "done")

        let outcome = try await outcomeTask.value
        #expect(outcome == .terminalClose(1000))
        #expect(await client.snapshot().phase == .terminated)
        await server.stop()
    }

    @Test func terminalCloseCodeFromRealSocketEndsConnectionWithoutReconnecting() async throws {
        let server = try await VoiceGatewayLoopbackServer.start()
        defer { server.stopEventually() }

        // A larger reconnect budget than the server ever exercises proves the terminal
        // disposition (4014, "Disconnected") wins on its own merits, not because reconnects
        // were disabled.
        let client = try makeLoopbackClient(
            port: server.port,
            configuration: .init(maximumReconnectAttempts: 3)
        )
        let connectionTask = Task { await server.nextConnection() }
        let outcomeTask = Task { try await client.connect() }

        guard let connection = await connectionTask.value else {
            Issue.record("Expected the client to complete a real WebSocket handshake")
            return
        }

        await connection.sendHello(heartbeatIntervalMilliseconds: 10_000)
        guard case .text(let identifyText) = await connection.receiveEvent() else {
            Issue.record("Expected an Identify frame over the real socket")
            return
        }
        #expect(opcode(of: identifyText) == VoiceGatewayV8Identify.opcode)

        await connection.closeConnection(code: 4014, reason: "Disconnected")

        let outcome = try await outcomeTask.value
        #expect(outcome == .terminalClose(4014))
        #expect(await server.acceptedConnectionCount() == 1)
        await server.stop()
    }

    @Test func missedHeartbeatAcknowledgementClosesRealSocketAndStopsAtReconnectLimit() async throws {
        let server = try await VoiceGatewayLoopbackServer.start()
        defer { server.stopEventually() }

        let client = try makeLoopbackClient(
            port: server.port,
            configuration: .init(maximumReconnectAttempts: 0, idleHeartbeatPollMilliseconds: 1)
        )
        let connectionTask = Task { await server.nextConnection() }
        let outcomeTask = Task { try await client.connect() }

        guard let connection = await connectionTask.value else {
            Issue.record("Expected the client to complete a real WebSocket handshake")
            return
        }

        // 100ms is the minimum interval `VoiceGatewayV8Hello` accepts (see
        // `VoiceGatewayV8Models.swift`'s `(100...300_000)` bound); anything smaller is rejected
        // by the real client before it ever sends Identify.
        await connection.sendHello(heartbeatIntervalMilliseconds: 100)
        guard case .text(let identifyText) = await connection.receiveEvent() else {
            Issue.record("Expected an Identify frame over the real socket")
            return
        }
        #expect(opcode(of: identifyText) == VoiceGatewayV8Identify.opcode)

        guard case .text(let heartbeatText) = await connection.receiveEvent() else {
            Issue.record("Expected a Heartbeat frame over the real socket")
            return
        }
        #expect(opcode(of: heartbeatText) == VoiceGatewayV8Heartbeat.opcode)
        // Deliberately withhold the heartbeat ACK: the real client must notice on its own that
        // the deadline passed, then close the *real* socket itself rather than relying on a
        // fake transport's `keepOpenAfterMessages` toggle.

        guard case .closed(let code, _) = await connection.receiveEvent() else {
            Issue.record("Expected the client to close the real socket after a missed heartbeat ACK")
            return
        }
        #expect(code == 1001)

        let outcome = try await outcomeTask.value
        #expect(outcome == .reconnectLimitReached)
        await server.stop()
    }

    private func makeLoopbackClient(
        port: Int,
        token: String = "voice-token",
        udpHandoff: VoiceGatewayUDPHandoff = VoiceGatewayUDPHandoff { _ in
            VoiceGatewayUDPSelection(
                address: "198.51.100.20",
                port: 62_000,
                mode: "aead_xchacha20_poly1305_rtpsize"
            )
        },
        configuration: VoiceGatewayClient.Configuration = .init()
    ) throws -> VoiceGatewayClient {
        try VoiceGatewayClient(
            // The real production endpoint model requires `wss`; the loopback transport below
            // ignores this value entirely and connects to the real local server instead, the
            // same way the existing fake-transport tests inject a hermetic `Runner`.
            endpoint: VoiceGatewayV8Endpoint("voice.example.test"),
            identity: VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "user",
                sessionID: "session",
                token: token
            ),
            transport: .loopback(url: URL(string: "ws://127.0.0.1:\(port)/")!),
            udpHandoff: udpHandoff,
            configuration: configuration
        )
    }

    private func eventually(
        attempts: Int = 500,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Condition was not satisfied before timeout")
    }
}

private func opcode(of text: String) -> Int? {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["op"] as? Int
}

private func stringField(of text: String, key: String) -> String? {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = object["d"] as? [String: Any]
    else { return nil }
    return payload[key] as? String
}

// MARK: - Real WebSocket client transport over a raw loopback URL

extension VoiceGatewayClientTransport {
    /// Connects the exact `WSClient.WebSocketClient` production adapter (`.live()`) uses, but
    /// to a fixed loopback URL instead of one derived from the `VoiceGatewayV8Endpoint` the
    /// runner is invoked with (that model enforces `wss`, which a plaintext local test server
    /// cannot terminate). Everything downstream — `VoiceGatewayClientSession` bridging,
    /// `VoiceGatewayClientInboundBuffer` backpressure, `VoiceGatewayClientTaskCoordinator`
    /// cancellation — is the identical internal machinery `.live()` uses, made reachable here via
    /// `@testable import`. This is a real WebSocket client speaking to a real WebSocket server
    /// over a real loopback socket; only the TLS termination and endpoint source differ from
    /// production.
    static func loopback(
        url: URL,
        logger: Logger = Logger(label: "AbbeyCoreTests.VoiceGatewayLoopback")
    ) -> Self {
        Self { _, maximumMessageBytes, operation in
            let configuration = WebSocketClientConfiguration(
                maxFrameSize: maximumMessageBytes,
                closeTimeout: .seconds(5),
                autoPing: .disabled,
                validateUTF8: true
            )
            let client = WebSocketClient(
                url: url.absoluteString,
                configuration: configuration,
                logger: logger
            ) { inbound, outbound, _ in
                let maximumBufferedBytes = min(maximumMessageBytes * 8, 4 * 1_024 * 1_024)
                let inbox = VoiceGatewayClientInboundBuffer(
                    maximumMessages: 128,
                    maximumBytes: maximumBufferedBytes
                )
                let session = VoiceGatewayClientSession(
                    receiveFrame: {
                        try await inbox.nextFrame()
                    },
                    sendFrame: { frame in
                        guard frame.byteCount <= maximumMessageBytes else {
                            throw VoiceGatewayClientTransportError.messageTooLarge
                        }
                        switch frame {
                        case .text(let text):
                            try await outbound.write(.text(text))
                        case .binary(let data):
                            try await outbound.write(.binary(ByteBuffer(bytes: data)))
                        }
                    },
                    close: { code, reason in
                        guard (1_000...4_999).contains(code) else { return }
                        try? await outbound.close(.init(codeNumber: code), reason: reason)
                    }
                )

                try await VoiceGatewayClientTaskCoordinator.run(
                    operation: {
                        try await operation(session)
                    },
                    inbound: {
                        do {
                            for try await message in inbound.messages(maxSize: maximumMessageBytes) {
                                switch message {
                                case .text(let text):
                                    guard text.utf8.count <= maximumMessageBytes else {
                                        throw VoiceGatewayClientTransportError.messageTooLarge
                                    }
                                    do {
                                        try await inbox.yield(.text(text))
                                    } catch {
                                        try? await outbound.close(
                                            .init(codeNumber: VoiceGatewayClientInboundBuffer.overflowCloseCode),
                                            reason: "inbound queue overflow"
                                        )
                                        throw error
                                    }
                                case .binary(let buffer):
                                    guard buffer.readableBytes <= maximumMessageBytes else {
                                        throw VoiceGatewayClientTransportError.messageTooLarge
                                    }
                                    do {
                                        try await inbox.yield(.binary(Data(buffer.readableBytesView)))
                                    } catch {
                                        try? await outbound.close(
                                            .init(codeNumber: VoiceGatewayClientInboundBuffer.overflowCloseCode),
                                            reason: "inbound queue overflow"
                                        )
                                        throw error
                                    }
                                }
                            }
                            await inbox.finish()
                        } catch {
                            let mapped: any Error
                            if let clientError = error as? WebSocketClientError {
                                if clientError == .serverSentMessageTooLarge {
                                    mapped = VoiceGatewayClientTransportError.messageTooLarge
                                } else if clientError == .serverSentDataInconsistentWithMessage {
                                    mapped = VoiceGatewayClientTransportError.invalidTextEncoding
                                } else {
                                    mapped = error
                                }
                            } else {
                                mapped = error
                            }
                            await inbox.finish(throwing: mapped)
                            throw mapped
                        }
                    },
                    operationCompleted: {
                        await inbox.finish()
                    },
                    cancelled: {
                        await inbox.finish(throwing: CancellationError())
                        try? await outbound.close(.goingAway, reason: "cancelled")
                    }
                )
            }

            let close = try await client.run()
            return close.map {
                VoiceGatewayClientClose(
                    code: Int(UInt16(webSocketErrorCode: $0.closeCode)),
                    reason: $0.reason
                )
            }
        }
    }
}

// MARK: - Real, in-process Voice Gateway WebSocket server

/// A real WebSocket server bound to `127.0.0.1:0` (ephemeral port; no fixed-port conflicts, no
/// live Discord dependency), built directly on SwiftNIO's `NIOTypedWebSocketServerUpgrader` —
/// the same primitive `swift-nio`'s own `NIOWebSocketServer` example target uses. It performs a
/// genuine HTTP/1.1 Upgrade handshake and speaks real WebSocket frames, so it can be scripted
/// per-test to send Discord Voice Gateway v8 opcodes (Hello, Ready, Session Description,
/// heartbeat ACK, close codes) to a connecting `VoiceGatewayClient`.
actor VoiceGatewayLoopbackServer {
    private enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded
    }

    enum ServerError: Error {
        case bindFailed
    }

    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let listener: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never>
    private var pendingConnections: [VoiceGatewayLoopbackConnection] = []
    private var connectionWaiters: [CheckedContinuation<VoiceGatewayLoopbackConnection?, Never>] = []
    private var acceptingFinished = false
    private var acceptedConnections = 0
    private var acceptLoopTask: Task<Void, Never>?
    private var stopped = false

    private init(
        port: Int,
        group: MultiThreadedEventLoopGroup,
        listener: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never>
    ) {
        self.port = port
        self.group = group
        self.listener = listener
    }

    static func start() async throws -> VoiceGatewayLoopbackServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let listener: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never> = try await ServerBootstrap(
                group: group
            )
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                        shouldUpgrade: { channel, _ in
                            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        },
                        upgradePipelineHandler: { channel, _ in
                            channel.eventLoop.makeCompletedFuture {
                                UpgradeResult.websocket(
                                    try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                        wrappingChannelSynchronously: channel
                                    )
                                )
                            }
                        }
                    )
                    let upgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration<UpgradeResult>(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeSucceededFuture(UpgradeResult.notUpgraded)
                        }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: upgradeConfiguration)
                    )
                }
            }
            guard let port = listener.channel.localAddress?.port else {
                try await listener.channel.close()
                try await group.shutdownGracefully()
                throw ServerError.bindFailed
            }
            let server = VoiceGatewayLoopbackServer(port: port, group: group, listener: listener)
            await server.startAcceptLoop()
            return server
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// Waits for the next client to complete a real WebSocket handshake.
    func nextConnection() async -> VoiceGatewayLoopbackConnection? {
        if !pendingConnections.isEmpty { return pendingConnections.removeFirst() }
        if acceptingFinished { return nil }
        return await withCheckedContinuation { connectionWaiters.append($0) }
    }

    func acceptedConnectionCount() -> Int { acceptedConnections }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        finishAccepting()
        acceptLoopTask?.cancel()
        try? await listener.channel.close()
        _ = await acceptLoopTask?.result
        try? await group.shutdownGracefully()
    }

    nonisolated func stopEventually() {
        Task { await self.stop() }
    }

    private func startAcceptLoop() {
        acceptLoopTask = Task { [weak self] in
            await self?.acceptLoop()
        }
    }

    private func acceptLoop() async {
        do {
            try await listener.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await upgradeResultFuture in inbound {
                        group.addTask { [weak self] in
                            await self?.handle(upgradeResultFuture)
                        }
                    }
                }
            }
        } catch {
            // Listener teardown/cancellation is an expected test-server exit.
        }
        finishAccepting()
    }

    private func publish(_ connection: VoiceGatewayLoopbackConnection) {
        if !connectionWaiters.isEmpty {
            connectionWaiters.removeFirst().resume(returning: connection)
        } else {
            pendingConnections.append(connection)
        }
    }

    private func finishAccepting() {
        guard !acceptingFinished else { return }
        acceptingFinished = true
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    private func handle(_ future: EventLoopFuture<UpgradeResult>) async {
        guard let result = try? await future.get(), case .websocket(let webSocketChannel) = result else {
            return
        }
        acceptedConnections += 1
        let connection = VoiceGatewayLoopbackConnection()
        publish(connection)

        do {
            try await webSocketChannel.executeThenClose { inbound, outbound in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await frame in inbound {
                            switch frame.opcode {
                            case .text:
                                var data = frame.unmaskedData
                                let text = data.readString(length: data.readableBytes) ?? ""
                                await connection.deliverInbound(.text(text))
                            case .binary:
                                var data = frame.unmaskedData
                                let bytes = data.readBytes(length: data.readableBytes) ?? []
                                await connection.deliverInbound(.binary(bytes))
                            case .ping:
                                var frameData = frame.data
                                if let maskingKey = frame.maskKey {
                                    frameData.webSocketUnmask(maskingKey)
                                }
                                try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frameData))
                            case .connectionClose:
                                var data = frame.unmaskedData
                                let code: UInt16? = data.readableBytes >= 2 ? data.readInteger() : nil
                                let reason = data.readableBytes > 0
                                    ? data.readString(length: data.readableBytes)
                                    : nil
                                await connection.deliverInbound(.closed(code: code, reason: reason))
                                return
                            default:
                                break
                            }
                        }
                        await connection.deliverInbound(.ended)
                    }
                    group.addTask {
                        for await frame in connection.outboundFrames {
                            try await outbound.write(frame)
                        }
                    }
                    try await group.next()
                    group.cancelAll()
                }
            }
        } catch {
            await connection.deliverInbound(.ended)
        }
    }
}

/// One accepted, real WebSocket connection to `VoiceGatewayLoopbackServer`. Provides a scripting
/// API for the Voice Gateway v8 opcodes production sends (Hello/Ready/Session
/// Description/heartbeat ACK/close) and an inspection API for what the real client actually put
/// on the wire.
actor VoiceGatewayLoopbackConnection {
    enum InboundEvent: Sendable {
        case text(String)
        case binary([UInt8])
        case closed(code: UInt16?, reason: String?)
        /// The underlying socket ended without a WebSocket close frame (abrupt disconnect).
        case ended
    }

    nonisolated let outboundFrames: AsyncStream<WebSocketFrame>
    private let outboundContinuation: AsyncStream<WebSocketFrame>.Continuation

    private var bufferedInbound: [InboundEvent] = []
    private var inboundWaiters: [CheckedContinuation<InboundEvent, Never>] = []
    private var inboundClosed = false

    init() {
        var continuation: AsyncStream<WebSocketFrame>.Continuation!
        self.outboundFrames = AsyncStream { continuation = $0 }
        self.outboundContinuation = continuation
    }

    // MARK: Inbound (client -> server) inspection

    func deliverInbound(_ event: InboundEvent) {
        switch event {
        case .closed, .ended: inboundClosed = true
        default: break
        }
        if !inboundWaiters.isEmpty {
            inboundWaiters.removeFirst().resume(returning: event)
        } else {
            bufferedInbound.append(event)
        }
    }

    /// Waits for the next frame-level event the client sent, in order.
    func receiveEvent() async -> InboundEvent {
        if !bufferedInbound.isEmpty { return bufferedInbound.removeFirst() }
        if inboundClosed { return .ended }
        return await withCheckedContinuation { inboundWaiters.append($0) }
    }

    // MARK: Outbound (server -> client) scripting

    func sendHello(heartbeatIntervalMilliseconds: UInt64) {
        sendText(#"{"op":8,"d":{"heartbeat_interval":\#(heartbeatIntervalMilliseconds)}}"#)
    }

    func sendReady(ssrc: UInt32, ip: String, port: UInt16, modes: [String], sequence: Int) {
        let modeList = modes.map { #""\#($0)""# }.joined(separator: ",")
        sendText(
            #"{"op":2,"seq":\#(sequence),"d":{"ssrc":\#(ssrc),"ip":"\#(ip)","port":\#(port),"modes":[\#(modeList)]}}"#
        )
    }

    func sendSessionDescription(mode: String, sequence: Int, daveProtocolVersion: Int = 0) {
        let key = Array(repeating: "1", count: 32).joined(separator: ",")
        sendText(
            #"{"op":4,"seq":\#(sequence),"d":{"mode":"\#(mode)","secret_key":[\#(key)],"dave_protocol_version":\#(daveProtocolVersion)}}"#
        )
    }

    func sendHeartbeatACK(t: UInt64) {
        sendText(#"{"op":6,"d":{"t":\#(t)}}"#)
    }

    func sendText(_ text: String) {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        outboundContinuation.yield(WebSocketFrame(fin: true, opcode: .text, data: buffer))
    }

    func closeConnection(code: UInt16, reason: String? = nil) {
        var buffer = ByteBufferAllocator().buffer(capacity: 2 + (reason?.utf8.count ?? 0))
        buffer.writeInteger(code)
        if let reason { buffer.writeString(reason) }
        outboundContinuation.yield(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer))
        outboundContinuation.finish()
    }
}
