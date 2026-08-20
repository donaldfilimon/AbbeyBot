import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import AbbeyCore

@Suite("Discord Voice UDP discovery")
struct DiscordVoiceUDPDiscoveryTests {
    @Test func requestFixtureIsExactlySeventyFourBigEndianBytes() {
        let request = DiscordVoiceUDPDiscoveryCodec.encodeRequest(ssrc: 0x1234_5678)

        #expect(request.count == 74)
        #expect(Array(request.prefix(8)) == [0, 1, 0, 70, 0x12, 0x34, 0x56, 0x78])
        #expect(request.dropFirst(8).allSatisfy { $0 == 0 })
    }

    @Test func responseFixtureDecodesAddressAndPort() throws {
        let response = makeResponse(
            ssrc: 0x1234_5678,
            address: Array("203.0.113.24".utf8),
            port: 62_000
        )

        #expect(
            try DiscordVoiceUDPDiscoveryCodec.decodeResponse(
                response,
                expectedSSRC: 0x1234_5678
            ) == DiscordVoiceUDPDiscoveryResult(address: "203.0.113.24", port: 62_000)
        )
    }

    @Test func responseRejectsEveryMalformedField() {
        let ssrc: UInt32 = 0x1234_5678
        let valid = makeResponse(ssrc: ssrc, address: Array("127.0.0.1".utf8), port: 50_000)

        expectCodecError(.invalidPacketSize, Array(valid.dropLast()), ssrc: ssrc)
        expectCodecError(.invalidPacketSize, valid + [0], ssrc: ssrc)

        var wrongType = valid
        wrongType[1] = 3
        expectCodecError(.invalidType, wrongType, ssrc: ssrc)

        var wrongLength = valid
        wrongLength[3] = 69
        expectCodecError(.invalidLength, wrongLength, ssrc: ssrc)

        expectCodecError(.ssrcMismatch, valid, ssrc: ssrc &+ 1)

        var unterminated = valid
        unterminated.replaceSubrange(8..<72, with: repeatElement(UInt8(ascii: "1"), count: 64))
        expectCodecError(.missingAddressTerminator, unterminated, ssrc: ssrc)

        var invalidUTF8 = valid
        invalidUTF8.replaceSubrange(8..<72, with: repeatElement(UInt8(0), count: 64))
        invalidUTF8[8] = 0xFF
        invalidUTF8[9] = 0
        expectCodecError(.invalidAddressEncoding, invalidUTF8, ssrc: ssrc)

        let invalidIP = makeResponse(ssrc: ssrc, address: Array("not-an-ip".utf8), port: 50_000)
        expectCodecError(.invalidAddress, invalidIP, ssrc: ssrc)

        var nonZeroPadding = valid
        nonZeroPadding[20] = 1
        expectCodecError(.nonZeroAddressPadding, nonZeroPadding, ssrc: ssrc)

        var zeroPort = valid
        zeroPort[72] = 0
        zeroPort[73] = 0
        expectCodecError(.invalidPort, zeroPort, ssrc: ssrc)
    }

    @Test func realLoopbackServerReceivesRequestAndReturnsDiscovery() async throws {
        let ssrc: UInt32 = 0xCAFE_BABE
        let server = try await LoopbackUDPServer.start { request in
            #expect(request == DiscordVoiceUDPDiscoveryCodec.encodeRequest(ssrc: ssrc))
            return makeResponse(
                ssrc: ssrc,
                address: Array("198.51.100.42".utf8),
                port: 61_234
            )
        }
        defer { server.stopEventually() }

        let result = try await DiscordVoiceUDPDiscoveryClient(
            configuration: .init(timeout: .seconds(2))
        ).discover(serverAddress: "127.0.0.1", serverPort: server.port, ssrc: ssrc)

        #expect(result == .init(address: "198.51.100.42", port: 61_234))
        await server.stop()
    }

    @Test func realLoopbackMalformedResponseIsRejected() async throws {
        let ssrc: UInt32 = 77
        let server = try await LoopbackUDPServer.start { _ in
            var response = makeResponse(
                ssrc: ssrc,
                address: Array("127.0.0.1".utf8),
                port: 50_000
            )
            response[1] = 9
            return response
        }
        defer { server.stopEventually() }

        await expectDiscoveryError(.invalidType) {
            try await DiscordVoiceUDPDiscoveryClient(
                configuration: .init(timeout: .seconds(2))
            ).discover(serverAddress: "127.0.0.1", serverPort: server.port, ssrc: ssrc)
        }
        await server.stop()
    }

    @Test func realLoopbackTimeoutClosesClientChannel() async throws {
        let requestSeen = UDPRequestGate()
        let server = try await LoopbackUDPServer.start { _ in
            await requestSeen.markSeen()
            return nil
        }
        defer { server.stopEventually() }
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        await expectDiscoveryError(.timeout) {
            try await DiscordVoiceUDPDiscoveryClient(
                configuration: .init(timeout: .milliseconds(50))
            ).discover(
                serverAddress: "127.0.0.1",
                serverPort: server.port,
                ssrc: 91,
                eventLoopGroup: clientGroup
            )
        }
        #expect(await requestSeen.wasSeen())
        await #expect(throws: Never.self) {
            try await clientGroup.shutdownGracefully()
        }
        await server.stop()
    }

    @Test func realLoopbackDroppedResponseTimesOutAndCallerRetrySucceeds() async throws {
        let ssrc: UInt32 = 93
        let drops = UDPFirstRequestDropper()
        let server = try await LoopbackUDPServer.start { request in
            #expect(request == DiscordVoiceUDPDiscoveryCodec.encodeRequest(ssrc: ssrc))
            guard await drops.shouldRespond() else { return nil }
            return makeResponse(
                ssrc: ssrc,
                address: Array("198.51.100.7".utf8),
                port: 40_000
            )
        }
        defer { server.stopEventually() }

        // Induced loss: the one-shot client has no in-call retransmit; the lost response
        // surfaces as a bounded timeout and retry is the caller's decision.
        await expectDiscoveryError(.timeout) {
            try await DiscordVoiceUDPDiscoveryClient(
                configuration: .init(timeout: .milliseconds(100))
            ).discover(serverAddress: "127.0.0.1", serverPort: server.port, ssrc: ssrc)
        }

        let result = try await DiscordVoiceUDPDiscoveryClient(
            configuration: .init(timeout: .seconds(2))
        ).discover(serverAddress: "127.0.0.1", serverPort: server.port, ssrc: ssrc)
        #expect(result == .init(address: "198.51.100.7", port: 40_000))
        #expect(await drops.requestCount() == 2)
        await server.stop()
    }

    @Test func realLoopbackTruncatedResponseFailsClosed() async throws {
        let ssrc: UInt32 = 94
        let server = try await LoopbackUDPServer.start { _ in
            Array(
                makeResponse(
                    ssrc: ssrc,
                    address: Array("127.0.0.1".utf8),
                    port: 50_000
                ).dropLast()
            )
        }
        defer { server.stopEventually() }

        await expectDiscoveryError(.invalidPacketSize) {
            try await DiscordVoiceUDPDiscoveryClient(
                configuration: .init(timeout: .seconds(2))
            ).discover(serverAddress: "127.0.0.1", serverPort: server.port, ssrc: ssrc)
        }
        await server.stop()
    }

    @Test func realLoopbackMismatchedSSRCResponseFailsClosed() async throws {
        let ssrc: UInt32 = 95
        let server = try await LoopbackUDPServer.start { _ in
            makeResponse(
                ssrc: ssrc &+ 1,
                address: Array("127.0.0.1".utf8),
                port: 50_000
            )
        }
        defer { server.stopEventually() }

        await expectDiscoveryError(.ssrcMismatch) {
            try await DiscordVoiceUDPDiscoveryClient(
                configuration: .init(timeout: .seconds(2))
            ).discover(serverAddress: "127.0.0.1", serverPort: server.port, ssrc: ssrc)
        }
        await server.stop()
    }

    @Test func realLoopbackCancellationClosesOwnedResources() async throws {
        let requestSeen = UDPRequestGate()
        let server = try await LoopbackUDPServer.start { _ in
            await requestSeen.markSeen()
            return nil
        }
        defer { server.stopEventually() }

        let discovery = Task {
            try await DiscordVoiceUDPDiscoveryClient(
                configuration: .init(timeout: .seconds(30))
            ).discover(serverAddress: "127.0.0.1", serverPort: server.port, ssrc: 92)
        }
        await requestSeen.waitUntilSeen()
        discovery.cancel()

        do {
            _ = try await discovery.value
            Issue.record("Expected discovery cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        await server.stop()
    }

    private func expectCodecError(
        _ expected: DiscordVoiceUDPDiscoveryError,
        _ response: [UInt8],
        ssrc: UInt32
    ) {
        do {
            _ = try DiscordVoiceUDPDiscoveryCodec.decodeResponse(response, expectedSSRC: ssrc)
            Issue.record("Expected codec error \(expected)")
        } catch let error as DiscordVoiceUDPDiscoveryError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected codec error type")
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
}

private func makeResponse(
    ssrc: UInt32,
    address: [UInt8],
    port: UInt16
) -> [UInt8] {
    precondition(address.count < 64)
    var response = [UInt8](repeating: 0, count: 74)
    response[0] = 0
    response[1] = 2
    response[2] = 0
    response[3] = 70
    response[4] = UInt8(truncatingIfNeeded: ssrc >> 24)
    response[5] = UInt8(truncatingIfNeeded: ssrc >> 16)
    response[6] = UInt8(truncatingIfNeeded: ssrc >> 8)
    response[7] = UInt8(truncatingIfNeeded: ssrc)
    response.replaceSubrange(8..<(8 + address.count), with: address)
    response[72] = UInt8(truncatingIfNeeded: port >> 8)
    response[73] = UInt8(truncatingIfNeeded: port)
    return response
}

private final class LoopbackUDPServer: @unchecked Sendable {
    typealias Response = @Sendable ([UInt8]) async -> [UInt8]?

    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>
    private let response: Response
    private let stopGate = UDPServerStopGate()
    private var task: Task<Void, Never>?

    private init(
        port: Int,
        group: MultiThreadedEventLoopGroup,
        channel: NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>,
        response: @escaping Response
    ) {
        self.port = port
        self.group = group
        self.channel = channel
        self.response = response
    }

    static func start(response: @escaping Response) async throws -> LoopbackUDPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await DatagramBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(
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
                throw DiscordVoiceUDPDiscoveryError.transportFailure
            }
            let server = LoopbackUDPServer(
                port: port,
                group: group,
                channel: channel,
                response: response
            )
            server.run()
            return server
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func run() {
        task = Task { [channel, response] in
            do {
                try await channel.executeThenClose { inbound, outbound in
                    for try await envelope in inbound {
                        let request = envelope.data.getBytes(
                            at: envelope.data.readerIndex,
                            length: envelope.data.readableBytes
                        ) ?? []
                        guard let bytes = await response(request) else { continue }
                        var buffer = channel.channel.allocator.buffer(capacity: bytes.count)
                        buffer.writeBytes(bytes)
                        try await outbound.write(
                            AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: buffer)
                        )
                        return
                    }
                }
            } catch {
                // Teardown and explicit cancellation are expected test-server exits.
            }
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

private actor UDPServerStopGate {
    private var stopping = false

    func beginStop() -> Bool {
        guard !stopping else { return false }
        stopping = true
        return true
    }
}

private actor UDPFirstRequestDropper {
    private var requestsSeen = 0

    func shouldRespond() -> Bool {
        requestsSeen += 1
        return requestsSeen > 1
    }

    func requestCount() -> Int {
        requestsSeen
    }
}

private actor UDPRequestGate {
    private var seen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markSeen() {
        guard !seen else { return }
        seen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitUntilSeen() async {
        guard !seen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func wasSeen() -> Bool { seen }
}
