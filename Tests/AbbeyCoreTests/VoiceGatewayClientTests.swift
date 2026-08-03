import Foundation
import Testing
@testable import AbbeyCore

@Suite("Discord Voice Gateway client")
struct VoiceGatewayClientTests {
    @Test func transcriptIdentifiesThenHandsReadyToUDPAndSelectsProtocol() async throws {
        let script = VoiceGatewayTestScript(
            messages: [
                #"{"op":8,"d":{"heartbeat_interval":1000}}"#,
                #"{"op":2,"seq":12,"d":{"ssrc":44,"ip":"203.0.113.8","port":50000,"modes":["aead_xchacha20_poly1305_rtpsize"]}}"#,
                sessionDescription(mode: "aead_xchacha20_poly1305_rtpsize"),
            ],
            close: VoiceGatewayClientClose(code: 1000, reason: "done")
        )
        let harness = VoiceGatewayTestTransport(scripts: [script])
        let handoff = VoiceGatewayReadyRecorder(
            selection: VoiceGatewayUDPSelection(
                address: "198.51.100.20",
                port: 62000,
                mode: "aead_xchacha20_poly1305_rtpsize"
            )
        )
        let client = try makeClient(
            transport: harness.transport,
            udpHandoff: VoiceGatewayUDPHandoff { ready in
                try await handoff.prepare(ready)
            }
        )

        #expect(try await client.connect() == .terminalClose(1000))
        #expect(await harness.sentOpcodes(attempt: 0) == [0, 1])
        #expect(await handoff.receivedSSRCs() == [44])
        #expect(await client.snapshot().phase == .terminated)
    }

    @Test func resumableCloseReconnectsWithResumeAndLastSequence() async throws {
        let scripts = [
            VoiceGatewayTestScript(
                messages: [
                    #"{"op":8,"d":{"heartbeat_interval":1000}}"#,
                    #"{"op":2,"seq":22,"d":{"ssrc":7,"ip":"203.0.113.7","port":50001,"modes":["mode"]}}"#,
                    sessionDescription(mode: "mode", sequence: 23),
                ],
                close: VoiceGatewayClientClose(code: 4015, reason: "recoverable")
            ),
            VoiceGatewayTestScript(
                messages: [
                    #"{"op":8,"d":{"heartbeat_interval":1000}}"#,
                    #"{"op":9,"seq":24,"d":{}}"#,
                ],
                close: VoiceGatewayClientClose(code: 1000, reason: "done")
            ),
        ]
        let harness = VoiceGatewayTestTransport(scripts: scripts)
        let client = try makeClient(
            transport: harness.transport,
            udpHandoff: VoiceGatewayUDPHandoff { _ in
                VoiceGatewayUDPSelection(address: "127.0.0.1", port: 50002, mode: "mode")
            }
        )

        #expect(try await client.connect() == .terminalClose(1000))
        #expect(await harness.sentOpcodes(attempt: 0).first == 0)
        #expect(await harness.sentOpcodes(attempt: 1).first == 7)
        #expect(await harness.sentInteger(attempt: 1, opcode: 7, key: "seq_ack") == 23)
        #expect(await harness.attemptCount() == 2)
    }

    @Test func missingHeartbeatAcknowledgementClosesAndStopsAtReconnectLimit() async throws {
        let script = VoiceGatewayTestScript(
            messages: [#"{"op":8,"d":{"heartbeat_interval":100}}"#],
            close: VoiceGatewayClientClose(code: 1006, reason: nil),
            keepOpenAfterMessages: true
        )
        let harness = VoiceGatewayTestTransport(scripts: [script])
        let clock = VoiceGatewayManualClock()
        let client = try makeClient(
            transport: harness.transport,
            clock: VoiceGatewayClientClock(
                now: { await clock.now() },
                sleep: { milliseconds in try await clock.sleep(milliseconds: milliseconds) }
            ),
            configuration: .init(maximumReconnectAttempts: 0, idleHeartbeatPollMilliseconds: 1)
        )
        let connection = Task { try await client.connect() }

        try await eventually { await harness.sentOpcodes(attempt: 0) == [0] }
        await clock.advance(to: 100)
        try await eventually { await harness.sentOpcodes(attempt: 0).contains(3) }
        await clock.advance(to: 200)

        #expect(try await connection.value == .reconnectLimitReached)
        #expect(await harness.closeCodes(attempt: 0).contains(1001))
    }

    @Test func explicitDisconnectWinsOverResumableClose() async throws {
        let harness = VoiceGatewayTestTransport(scripts: [
            VoiceGatewayTestScript(
                messages: [],
                close: VoiceGatewayClientClose(code: 4015, reason: "recoverable"),
                keepOpenAfterMessages: true
            )
        ])
        let client = try makeClient(transport: harness.transport)
        let connection = Task { try await client.connect() }

        try await eventually { await harness.attemptCount() == 1 }
        #expect(await harness.sentOpcodes(attempt: 0).isEmpty)
        await client.disconnect()

        #expect(try await connection.value == .disconnected)
        #expect(await harness.closeCodes(attempt: 0) == [1000])
        #expect(await harness.attemptCount() == 1)
    }

    @Test(arguments: [
        VoiceGatewayClientTransportError.binaryMessageRejected,
        VoiceGatewayClientTransportError.invalidTextEncoding,
        VoiceGatewayClientTransportError.messageTooLarge,
    ])
    func transportProtocolViolationsAreTerminal(error: VoiceGatewayClientTransportError) async throws {
        let transport = VoiceGatewayClientTransport { _, _, _ in throw error }
        let client = try makeClient(transport: transport)

        await #expect(throws: VoiceGatewayClientTransportError.self) {
            _ = try await client.connect()
        }
    }

    @Test func oversizedTextClosesWithMessageTooLarge() async throws {
        let harness = VoiceGatewayTestTransport(scripts: [
            VoiceGatewayTestScript(
                messages: [String(repeating: "x", count: 300)],
                close: VoiceGatewayClientClose(code: 1006, reason: nil)
            )
        ])
        let client = try makeClient(
            transport: harness.transport,
            configuration: .init(maximumMessageBytes: 256, maximumReconnectAttempts: 0)
        )

        await #expect(throws: VoiceGatewayClientTransportError.self) {
            _ = try await client.connect()
        }
        #expect(await harness.closeCodes(attempt: 0) == [1009])
    }

    @Test func descriptionsRedactCredentialsAndUntrustedCloseReason() throws {
        let token = "top-secret-voice-token"
        let client = try makeClient(token: token, transport: VoiceGatewayClientTransport { _, _, _ in nil })
        let close = VoiceGatewayClientClose(code: 4015, reason: token)

        #expect(!String(describing: client).contains(token))
        #expect(!String(reflecting: client).contains(token))
        #expect(!String(describing: close).contains(token))
        #expect(String(describing: close).contains("<redacted>"))
    }

    @Test func remoteCloseCompletesWhileUDPHandoffIsSuspended() async throws {
        let handoffStarted = VoiceGatewayAsyncSignal()
        let transport = VoiceGatewayClientTransport { _, maximumBytes, operation in
            let inbox = VoiceGatewayClientInboundBuffer(maximumMessages: 8, maximumBytes: maximumBytes)
            let session = VoiceGatewayClientSession(
                receive: { try await inbox.next() },
                send: { _ in },
                close: { _, _ in await inbox.finish() }
            )
            try await VoiceGatewayClientTaskCoordinator.run(
                operation: { try await operation(session) },
                inbound: {
                    try await inbox.yield(#"{"op":8,"d":{"heartbeat_interval":1000}}"#)
                    try await inbox.yield(#"{"op":2,"seq":12,"d":{"ssrc":44,"ip":"203.0.113.8","port":50000,"modes":["mode"]}}"#)
                    await handoffStarted.wait()
                    await inbox.finish()
                },
                operationCompleted: { await inbox.finish() },
                cancelled: { await inbox.finish(throwing: CancellationError()) }
            )
            return VoiceGatewayClientClose(code: 4015, reason: "remote close")
        }
        let client = try makeClient(
            transport: transport,
            udpHandoff: VoiceGatewayUDPHandoff { _ in
                await handoffStarted.signal()
                try await Task.sleep(for: .seconds(60))
                return VoiceGatewayUDPSelection(address: "127.0.0.1", port: 50_000, mode: "mode")
            },
            configuration: .init(maximumReconnectAttempts: 0)
        )

        #expect(try await client.connect() == .reconnectLimitReached)
    }

    @Test func coordinatorAwaitsCancelledChildrenBeforeReturning() async throws {
        let recorder = VoiceGatewayCoordinatorCancellationRecorder()
        let coordinator = Task {
            try await VoiceGatewayClientTaskCoordinator.run(
                operation: {
                    await recorder.started("operation")
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        await recorder.finished("operation")
                        throw error
                    }
                },
                inbound: {
                    await recorder.started("inbound")
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        await recorder.finished("inbound")
                        throw error
                    }
                },
                operationCompleted: {},
                cancelled: { await recorder.cleanedUp() }
            )
        }

        try await eventually { await recorder.startedCount() == 2 }
        coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await coordinator.value }
        #expect(await recorder.finishedValues().sorted() == ["inbound", "operation"])
        #expect(await recorder.cleanupCount() == 1)
    }

    @Test func stalledConsumerCannotGrowInboundQueueWithoutBound() async throws {
        let countBounded = VoiceGatewayClientInboundBuffer(maximumMessages: 2, maximumBytes: 100)
        try await countBounded.yield("first")
        try await countBounded.yield("second")
        await #expect(throws: VoiceGatewayClientTransportError.self) {
            try await countBounded.yield("third")
        }
        await #expect(throws: VoiceGatewayClientTransportError.self) {
            _ = try await countBounded.next()
        }

        let byteBounded = VoiceGatewayClientInboundBuffer(maximumMessages: 10, maximumBytes: 5)
        try await byteBounded.yield("1234")
        await #expect(throws: VoiceGatewayClientTransportError.self) {
            try await byteBounded.yield("56")
        }
        #expect(VoiceGatewayClientInboundBuffer.overflowCloseCode == 1009)
    }

    @Test func transportFramesPreserveBinaryWithoutRenderingPayloads() async throws {
        let bytes = Data([222, 173, 190, 239])
        let frame = VoiceGatewayClientFrame.binary(bytes)
        let frameBuffer = VoiceGatewayClientInboundBuffer(
            maximumMessages: 2,
            maximumBytes: 32
        )
        try await frameBuffer.yield(frame)
        #expect(try await frameBuffer.nextFrame() == frame)

        var rendered = ""
        dump(frame, to: &rendered)
        rendered += String(describing: frame)
        rendered += String(reflecting: frame)
        #expect(rendered.contains("<redacted>"))
        #expect(!rendered.contains("222"))
        #expect(!rendered.lowercased().contains("deadbeef"))

        let textCompatibility = VoiceGatewayClientInboundBuffer(
            maximumMessages: 2,
            maximumBytes: 32
        )
        try await textCompatibility.yield(frame)
        await #expect(throws: VoiceGatewayClientTransportError.binaryMessageRejected) {
            _ = try await textCompatibility.next()
        }
    }

    @Test func reconnectBackoffIsCappedExponentialWithInjectedJitter() async throws {
        let recorder = VoiceGatewayBackoffRecorder()
        let backoff = VoiceGatewayReconnectBackoff(
            baseMilliseconds: 100,
            maximumMilliseconds: 250,
            jitter: { $0 },
            sleep: { milliseconds in await recorder.record(milliseconds) }
        )
        let harness = VoiceGatewayTestTransport(scripts: [
            VoiceGatewayTestScript(messages: [], close: VoiceGatewayClientClose(code: 1006, reason: nil)),
            VoiceGatewayTestScript(messages: [], close: VoiceGatewayClientClose(code: 1006, reason: nil)),
            VoiceGatewayTestScript(messages: [], close: VoiceGatewayClientClose(code: 1000, reason: nil)),
        ])
        let client = try makeClient(
            transport: harness.transport,
            reconnectBackoff: backoff,
            configuration: .init(maximumReconnectAttempts: 2)
        )

        #expect(try await client.connect() == .terminalClose(1000))
        #expect(await recorder.values() == [125, 250])
        #expect(backoff.delayMilliseconds(attempt: 10) == 250)
    }

    @Test func explicitDisconnectCancelsPendingReconnectDelay() async throws {
        let gate = VoiceGatewayBackoffGate()
        let backoff = VoiceGatewayReconnectBackoff(
            baseMilliseconds: 100,
            maximumMilliseconds: 100,
            jitter: { _ in 0 },
            sleep: { milliseconds in try await gate.sleep(milliseconds: milliseconds) }
        )
        let harness = VoiceGatewayTestTransport(scripts: [
            VoiceGatewayTestScript(messages: [], close: VoiceGatewayClientClose(code: 1006, reason: nil))
        ])
        let client = try makeClient(
            transport: harness.transport,
            reconnectBackoff: backoff,
            configuration: .init(maximumReconnectAttempts: 3)
        )
        let connection = Task { try await client.connect() }

        try await eventually { await gate.values() == [100] }
        await client.disconnect()

        #expect(try await connection.value == .disconnected)
        #expect(await harness.attemptCount() == 1)
    }

    private func makeClient(
        token: String = "voice-token",
        transport: VoiceGatewayClientTransport,
        udpHandoff: VoiceGatewayUDPHandoff = .unavailable,
        clock: VoiceGatewayClientClock = .init(
            now: { 0 },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        ),
        reconnectBackoff: VoiceGatewayReconnectBackoff = .init(
            jitter: { _ in 0 },
            sleep: { _ in }
        ),
        configuration: VoiceGatewayClient.Configuration = .init()
    ) throws -> VoiceGatewayClient {
        try VoiceGatewayClient(
            endpoint: VoiceGatewayV8Endpoint("voice.example.test"),
            identity: VoiceGatewayV8Identify(
                serverID: "guild",
                userID: "user",
                sessionID: "session",
                token: token
            ),
            transport: transport,
            udpHandoff: udpHandoff,
            clock: clock,
            reconnectBackoff: reconnectBackoff,
            configuration: configuration
        )
    }

    private func sessionDescription(mode: String, sequence: Int = 13) -> String {
        let key = Array(repeating: "1", count: 32).joined(separator: ",")
        return #"{"op":4,"seq":\#(sequence),"d":{"mode":"\#(mode)","secret_key":[\#(key)],"dave_protocol_version":0}}"#
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

private struct VoiceGatewayTestScript: Sendable {
    let messages: [String]
    let close: VoiceGatewayClientClose?
    var keepOpenAfterMessages = false
}

private actor VoiceGatewayTestTransport {
    private let scripts: [VoiceGatewayTestScript]
    private var sockets: [VoiceGatewayTestSocket] = []

    init(scripts: [VoiceGatewayTestScript]) {
        self.scripts = scripts
    }

    nonisolated var transport: VoiceGatewayClientTransport {
        VoiceGatewayClientTransport { [self] _, _, operation in
            let (socket, close) = try await nextAttempt()
            try await operation(socket.session)
            return close
        }
    }

    private func nextAttempt() throws -> (VoiceGatewayTestSocket, VoiceGatewayClientClose?) {
        let index = sockets.count
        guard scripts.indices.contains(index) else {
            throw VoiceGatewayClientTransportError.connectionClosed
        }
        let script = scripts[index]
        let socket = VoiceGatewayTestSocket(
            messages: script.messages,
            keepOpenAfterMessages: script.keepOpenAfterMessages
        )
        sockets.append(socket)
        return (socket, script.close)
    }

    func attemptCount() -> Int { sockets.count }

    func sentOpcodes(attempt: Int) async -> [Int] {
        guard sockets.indices.contains(attempt) else { return [] }
        return await sockets[attempt].sentOpcodes()
    }

    func sentInteger(attempt: Int, opcode: Int, key: String) async -> Int? {
        guard sockets.indices.contains(attempt) else { return nil }
        return await sockets[attempt].sentInteger(opcode: opcode, key: key)
    }

    func closeCodes(attempt: Int) async -> [Int] {
        guard sockets.indices.contains(attempt) else { return [] }
        return await sockets[attempt].closeCodes()
    }
}

private actor VoiceGatewayTestSocket {
    private typealias Waiter = CheckedContinuation<String?, Never>

    private var messages: [String]
    private let keepOpenAfterMessages: Bool
    private var sent: [String] = []
    private var closes: [Int] = []
    private var waiters: [Waiter] = []
    private var closed = false

    init(messages: [String], keepOpenAfterMessages: Bool) {
        self.messages = messages
        self.keepOpenAfterMessages = keepOpenAfterMessages
    }

    nonisolated var session: VoiceGatewayClientSession {
        VoiceGatewayClientSession(
            receive: { [self] in await receive() },
            send: { [self] text in await recordSent(text) },
            close: { [self] code, _ in await recordClose(code) }
        )
    }

    private func receive() async -> String? {
        if !messages.isEmpty { return messages.removeFirst() }
        guard keepOpenAfterMessages, !closed else { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func recordSent(_ text: String) { sent.append(text) }

    private func recordClose(_ code: Int) {
        closes.append(code)
        closed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }

    func sentOpcodes() -> [Int] {
        sent.compactMap { text in
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["op"] as? Int
        }
    }

    func sentInteger(opcode: Int, key: String) -> Int? {
        for text in sent {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["op"] as? Int == opcode,
                  let payload = object["d"] as? [String: Any]
            else { continue }
            if let value = payload[key] as? Int { return value }
        }
        return nil
    }

    func closeCodes() -> [Int] { closes }
}

private actor VoiceGatewayReadyRecorder {
    private let selection: VoiceGatewayUDPSelection
    private var ssrcs: [UInt32] = []

    init(selection: VoiceGatewayUDPSelection) { self.selection = selection }

    func prepare(_ ready: VoiceGatewayV8Ready) throws -> VoiceGatewayUDPSelection {
        ssrcs.append(ready.ssrc)
        return selection
    }

    func receivedSSRCs() -> [UInt32] { ssrcs }
}

private actor VoiceGatewayManualClock {
    private var milliseconds: UInt64 = 0

    func now() -> UInt64 { milliseconds }

    func advance(to value: UInt64) { milliseconds = max(milliseconds, value) }

    func sleep(milliseconds delay: UInt64) async throws {
        let target = self.milliseconds + delay
        while self.milliseconds < target {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor VoiceGatewayAsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor VoiceGatewayBackoffRecorder {
    private var recorded: [UInt64] = []
    func record(_ value: UInt64) { recorded.append(value) }
    func values() -> [UInt64] { recorded }
}

private actor VoiceGatewayCoordinatorCancellationRecorder {
    private var startedValues: [String] = []
    private var completedValues: [String] = []
    private var cleanups = 0

    func started(_ value: String) { startedValues.append(value) }
    func finished(_ value: String) { completedValues.append(value) }
    func cleanedUp() { cleanups += 1 }
    func startedCount() -> Int { startedValues.count }
    func finishedValues() -> [String] { completedValues }
    func cleanupCount() -> Int { cleanups }
}

private actor VoiceGatewayBackoffGate {
    private var recorded: [UInt64] = []
    private var waiter: CheckedContinuation<Void, any Error>?

    func sleep(milliseconds: UInt64) async throws {
        recorded.append(milliseconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func values() -> [UInt64] { recorded }

    private func cancel() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
