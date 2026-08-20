import AbbeyCore
import Foundation
import Testing
@testable import AbbeyMediaNative

/// Phase 6a: proves the portable capture loop drives the real Phase 5 send
/// path — fake capture source in, DAVE-protected AEAD-sealed RTP packets out
/// of the retained transport — with Speaking exactly once and ordered
/// teardown ahead of the media reset.
@Suite("Capture loop against the native media plane")
struct DiscordVoiceCaptureLoopNativeCompositionTests {
    @Test("pumped PCM frames become protected wire packets in order, after one Speaking signal")
    func captureLoopComposesTheProtectedSendPath() async throws {
        let transport = CompositionDatagramDouble()
        let daveSession = CompositionDAVESessionDouble(protocolVersion: 1, isMediaReady: true)
        let speaking = CompositionSpeakingRecorder()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { daveSession },
            datagramTransport: transport,
            makeRTPClockSeed: { (5_000, 96_000) }
        )
        await plane.attachSpeakingSignal { try await speaking.signal() }
        _ = try await plane.install(
            try DiscordVoiceNegotiatedMediaCapability(
                generation: 30,
                ssrc: 0x2222_2222,
                transportMode: .aeadXChaCha20Poly1305RTPSIZE,
                transportKey: [UInt8](repeating: 0x5c, count: 32),
                daveProtocolVersion: 1
            )
        )

        let source = CompositionCaptureSourceDouble()
        let loop = DiscordVoiceCaptureLoop(source: source, sender: plane)
        try await loop.start(generation: 30)

        await source.emit(compositionPCMFrame(seed: 0))
        await source.emit(compositionPCMFrame(seed: 1))
        #expect(await waitForCondition { await transport.sentPackets.count == 2 })

        #expect(await speaking.callCount == 1)
        #expect(await daveSession.protectCallCount == 2)

        // AEAD counters advance per packet, so the loop sends in order and
        // never duplicates a frame.
        let packets = await transport.sentPackets
        let counters = packets.map { packet in
            packet.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        #expect(counters == [0, 1])

        // Ordered teardown: the loop's stop completes (capture stopped, pump
        // drained) before the media plane reset, and nothing sends after it.
        await loop.stop()
        await plane.reset()
        await source.emit(compositionPCMFrame(seed: 2))
        for _ in 0..<50 { await Task.yield() }
        #expect(await transport.sentPackets.count == 2)
        #expect(await loop.snapshot().phase == .stopped)
        #expect(await loop.snapshot().sentFrameCount == 2)
    }

    @Test("a capture loop started before negotiation sends nothing and fails closed")
    func captureLoopBeforeNegotiationFailsClosed() async throws {
        let transport = CompositionDatagramDouble()
        let plane = DiscordVoiceNativeMediaPlane(
            aes256GCMAvailable: false,
            daveSessionProvider: { nil },
            datagramTransport: transport
        )
        let source = CompositionCaptureSourceDouble()
        let loop = DiscordVoiceCaptureLoop(source: source, sender: plane)

        try await loop.start(generation: 1)
        await source.emit(compositionPCMFrame(seed: 0))

        #expect(await waitForCondition { await loop.snapshot().phase == .failed })
        #expect(await transport.sentPackets.isEmpty)
        #expect(await source.stopCount >= 1)
    }
}

private func compositionPCMFrame(seed: Int) -> [Int16] {
    (0..<Opus20msCodec.interleavedSampleCount).map { index in
        Int16(truncatingIfNeeded: (index * 41) + (seed * 977) + 3)
    }
}

private func waitForCondition(_ condition: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<20_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

private actor CompositionCaptureSourceDouble: DiscordVoiceCaptureSource {
    private(set) var stopCount = 0
    private var continuation: AsyncStream<[Int16]>.Continuation?

    func startCapture() async throws -> AsyncStream<[Int16]> {
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        return stream
    }

    func stopCapture() async {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emit(_ pcm: [Int16]) {
        continuation?.yield(pcm)
    }
}

private actor CompositionDAVESessionDouble: DiscordVoiceNativeDAVEMediaSession {
    let protocolVersion: UInt16
    let isMediaReady: Bool
    private(set) var protectCallCount = 0

    init(protocolVersion: UInt16, isMediaReady: Bool) {
        self.protocolVersion = protocolVersion
        self.isMediaReady = isMediaReady
    }

    /// Deterministic non-identity transform standing in for MLS protection;
    /// see `NativeDAVEMediaSessionDouble` in the Phase 5 suite for why real
    /// MLS ciphertext cannot be produced in this environment.
    func protect(
        _ frame: Data,
        mediaType: NativeDAVEMediaType,
        codec: NativeDAVECodec,
        ssrc: UInt32
    ) throws -> Data {
        protectCallCount += 1
        return Data(frame.map { $0 ^ 0xff })
    }
}

private actor CompositionSpeakingRecorder {
    private(set) var callCount = 0
    func signal() throws { callCount += 1 }
}

private actor CompositionDatagramDouble: DiscordVoiceMediaDatagramTransport {
    private(set) var sentPackets: [[UInt8]] = []

    func sendProtectedPacket(_ bytes: [UInt8]) async throws {
        sentPackets.append(bytes)
    }

    func receiveProtectedPacket() async throws -> [UInt8] { [] }

    func disconnect() async {}
}
