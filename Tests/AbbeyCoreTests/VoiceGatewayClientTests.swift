import Foundation
import Testing
@testable import AbbeyCore

@Suite("Discord Voice Gateway client")
struct VoiceGatewayClientTests {
    @Test func transcriptIdentifiesThenHandsReadyToUDPAndSelectsProtocol() async throws {
        let script = VoiceGatewayTestScript(
            messages: [
                #"{"op":8,"d":{"heartbeat_interval":1000}}"#,
                #"{"op":2,"s":12,"d":{"ssrc":44,"ip":"203.0.113.8","port":50000,"modes":["aead_xchacha20_poly1305_rtpsize"]}}"#,
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
                    #"{"op":2,"s":22,"d":{"ssrc":7,"ip":"203.0.113.7","port":50001,"modes":["mode"]}}"#,
                ],
                close: VoiceGatewayClientClose(code: 4015, reason: "recoverable")
            ),
            VoiceGatewayTestScript(
                messages: [
                    #"{"op":8,"d":{"heartbeat_interval":1000}}"#,
                    #"{"op":9,"s":23,"d":{}}"#,
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
        #expect(await harness.sentInteger(attempt: 1, opcode: 7, key: "seq_ack") == 22)
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

        try await eventually { await harness.sentOpcodes(attempt: 0) == [0] }
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

    private func makeClient(
        token: String = "voice-token",
        transport: VoiceGatewayClientTransport,
        udpHandoff: VoiceGatewayUDPHandoff = .unavailable,
        clock: VoiceGatewayClientClock = .init(
            now: { 0 },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
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
            configuration: configuration
        )
    }

    private func sessionDescription(mode: String) -> String {
        let key = Array(repeating: "1", count: 32).joined(separator: ",")
        return #"{"op":4,"s":13,"d":{"mode":"\#(mode)","secret_key":[\#(key)],"dave_protocol_version":0}}"#
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
