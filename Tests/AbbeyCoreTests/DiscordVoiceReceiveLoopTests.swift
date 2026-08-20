import Foundation
import Testing
@testable import AbbeyCore

private enum ReceiveLoopTestError: Error, Equatable {
    case transportFailed
    case decodeFailed
    case concealFailed
    case playbackFailed
}

// MARK: - Deterministic doubles

/// Manual monotonic clock. Time only moves when a test moves it, so eviction is
/// reproducible without a single sleep.
private final class ManualReceiveClock: DiscordVoiceReceiveClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero

    func now() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by delta: Duration) {
        lock.lock()
        value += delta
        lock.unlock()
    }
}

/// Datagram transport double. Serves a FIFO of scripted items and otherwise
/// parks, exactly like a real socket with no traffic. Cancellation-aware — which
/// is what the receive loop's ordered teardown depends on.
private actor ReceiveTransportDouble: DiscordVoiceMediaDatagramTransport {
    private enum Item {
        case packet([UInt8])
        case failure
    }

    private var items: [Item] = []
    private var waiter: CheckedContinuation<Item, any Error>?
    private(set) var receiveCallCount = 0
    private(set) var disconnectCount = 0

    func enqueue(_ packet: [UInt8]) { deliver(.packet(packet)) }
    func enqueueFailure() { deliver(.failure) }

    private func deliver(_ item: Item) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: item)
        } else {
            items.append(item)
        }
    }

    func sendProtectedPacket(_ bytes: [UInt8]) async throws {}

    func receiveProtectedPacket() async throws -> [UInt8] {
        receiveCallCount += 1
        let item: Item
        if items.isEmpty {
            item = try await waitForItem()
        } else {
            item = items.removeFirst()
        }
        switch item {
        case .packet(let bytes): return bytes
        case .failure: throw ReceiveLoopTestError.transportFailed
        }
    }

    /// Mirrors `DiscordVoiceUDPSession`'s structure: the cancellation handler
    /// stays outside the actor-isolated continuation setup.
    private func waitForItem() async throws -> Item {
        try await withTaskCancellationHandler(
            operation: { try await self.installWaiter() },
            onCancel: { Task { await self.cancelWaiter() } }
        )
    }

    private func installWaiter() async throws -> Item {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Item, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiter = continuation
            }
        }
    }

    private func cancelWaiter() {
        let pending = waiter
        waiter = nil
        pending?.resume(throwing: CancellationError())
    }

    func disconnect() async { disconnectCount += 1 }
}

/// Stands in for the native media plane's receive entry point. It never sees a
/// key; the test scripts what each protected packet decodes to.
private actor ReceiveDecoderDouble: DiscordVoiceAudioFrameDecoder {
    private(set) var decodedPackets: [[UInt8]] = []
    private(set) var concealedSSRCs: [UInt32] = []
    private var failingPayloads: Set<UInt8> = []
    private var concealFails = false
    private var overrideSSRC: UInt32?
    private let sampleCount: Int

    init(sampleCount: Int = 2) {
        self.sampleCount = sampleCount
    }

    /// Makes the plane reject any packet whose last byte matches — the
    /// fail-closed AEAD/DAVE stand-in.
    func failPacketsTagged(_ tag: UInt8) { failingPayloads.insert(tag) }
    func failConcealment() { concealFails = true }
    /// Forces the plane to attribute frames to a different SSRC than the header.
    func attributeEverythingTo(ssrc: UInt32) { overrideSSRC = ssrc }

    func decodeAudioFrame(packet: [UInt8]) async throws -> DiscordVoiceDecodedAudio {
        if let tag = packet.last, failingPayloads.contains(tag) {
            throw ReceiveLoopTestError.decodeFailed
        }
        decodedPackets.append(packet)
        let header = try DiscordVoiceRTPCodec().decodeHeader(from: packet)
        // Encode the sequence number into the PCM so playback assertions can
        // identify which frame was played, in what order.
        let sample = Int16(truncatingIfNeeded: header.sequence)
        return DiscordVoiceDecodedAudio(
            ssrc: overrideSSRC ?? header.ssrc,
            pcm: [Int16](repeating: sample, count: sampleCount)
        )
    }

    func concealAudioFrame(ssrc: UInt32) async throws -> [Int16] {
        if concealFails { throw ReceiveLoopTestError.concealFailed }
        concealedSSRCs.append(ssrc)
        return [Int16](repeating: -1, count: sampleCount)
    }
}

/// Playback double with a frame-count expectation, so tests await exactly the
/// progress they need instead of polling or sleeping.
private actor PlaybackSinkDouble: DiscordVoicePlaybackSink {
    private var frames: [[Int16]] = []
    private var expectedCount: Int?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var failFromFrameIndex: Int?

    func failFromFrame(_ index: Int) { failFromFrameIndex = index }

    func play(pcm: [Int16]) async throws {
        if let failFromFrameIndex, frames.count >= failFromFrameIndex {
            throw ReceiveLoopTestError.playbackFailed
        }
        frames.append(pcm)
        if let expectedCount, frames.count >= expectedCount {
            self.expectedCount = nil
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    func recorded() -> [[Int16]] { frames }

    func waitForFrames(_ count: Int) async {
        if frames.count >= count { return }
        expectedCount = count
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor TerminalRecorder {
    private(set) var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        count += 1
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if count > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - Packet construction

/// Builds a minimal, well-formed RTP packet: version 2, no padding, no CSRCs,
/// no extension. `tag` becomes the last payload byte so a decoder double can
/// single out one packet without ever inspecting real media.
private func makeRTPPacket(
    payloadType: UInt8 = DiscordVoiceRTPHeader.discordAudioPayloadType,
    sequence: UInt16,
    ssrc: UInt32,
    tag: UInt8 = 0
) -> [UInt8] {
    var packet: [UInt8] = [0x80, payloadType]
    packet += [UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
    let timestamp = UInt32(sequence) &* 960
    packet += (0..<4).map { UInt8(truncatingIfNeeded: timestamp >> (8 * (3 - $0))) }
    packet += (0..<4).map { UInt8(truncatingIfNeeded: ssrc >> (8 * (3 - $0))) }
    packet += [0xAB, 0xCD, tag]
    return packet
}

@Suite("Discord Voice receive loop composition")
struct DiscordVoiceReceiveLoopTests {
    private func makeLoop(
        transport: ReceiveTransportDouble,
        decoder: ReceiveDecoderDouble,
        sink: PlaybackSinkDouble,
        clock: ManualReceiveClock,
        targetDepth: Int = 4,
        idleTimeout: Duration = .seconds(5),
        maximumStreams: Int = 64
    ) throws -> DiscordVoiceReceiveLoop {
        try DiscordVoiceReceiveLoop(
            transport: transport,
            decoder: decoder,
            sink: sink,
            configuration: .init(
                targetDepth: targetDepth,
                idleTimeout: idleTimeout,
                maximumStreams: maximumStreams
            ),
            clock: clock
        )
    }

    @Test("A zero or lower generation is rejected as stale")
    func staleGenerationIsRejected() async throws {
        let loop = try makeLoop(
            transport: ReceiveTransportDouble(),
            decoder: ReceiveDecoderDouble(),
            sink: PlaybackSinkDouble(),
            clock: ManualReceiveClock()
        )
        await #expect(throws: DiscordVoiceReceiveLoopError.staleGeneration) {
            try await loop.start(generation: 0)
        }
        try await loop.start(generation: 4)
        await loop.stop()
        await #expect(throws: DiscordVoiceReceiveLoopError.staleGeneration) {
            try await loop.start(generation: 3)
        }
        await loop.stop()
    }

    @Test("A second start while running is rejected")
    func doubleStartIsRejected() async throws {
        let loop = try makeLoop(
            transport: ReceiveTransportDouble(),
            decoder: ReceiveDecoderDouble(),
            sink: PlaybackSinkDouble(),
            clock: ManualReceiveClock()
        )
        try await loop.start(generation: 1)
        await #expect(throws: DiscordVoiceReceiveLoopError.alreadyRunning) {
            try await loop.start(generation: 1)
        }
        await loop.stop()
    }

    @Test("Decoded frames reach playback in sequence order")
    func decodedFramesReachPlaybackInOrder() async throws {
        let transport = ReceiveTransportDouble()
        let decoder = ReceiveDecoderDouble()
        let sink = PlaybackSinkDouble()
        let loop = try makeLoop(
            transport: transport,
            decoder: decoder,
            sink: sink,
            clock: ManualReceiveClock()
        )
        try await loop.start(generation: 1)
        for sequence in UInt16(0)...UInt16(7) {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await sink.waitForFrames(4)
        await loop.stop()
        #expect(await sink.recorded() == [[0, 0], [1, 1], [2, 2], [3, 3]])
    }

    @Test("Reordering inside the buffer depth is repaired before playback")
    func reorderingIsRepairedBeforePlayback() async throws {
        let transport = ReceiveTransportDouble()
        let sink = PlaybackSinkDouble()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: sink,
            clock: ManualReceiveClock()
        )
        try await loop.start(generation: 1)
        for sequence in [0, 1, 3, 2, 4, 6, 5, 7] as [UInt16] {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await sink.waitForFrames(4)
        await loop.stop()
        #expect(await sink.recorded() == [[0, 0], [1, 1], [2, 2], [3, 3]])
    }

    @Test("A gap beyond the buffer depth is concealed through the decode path")
    func gapBeyondDepthIsConcealed() async throws {
        let transport = ReceiveTransportDouble()
        let decoder = ReceiveDecoderDouble()
        let sink = PlaybackSinkDouble()
        let loop = try makeLoop(
            transport: transport,
            decoder: decoder,
            sink: sink,
            clock: ManualReceiveClock()
        )
        try await loop.start(generation: 1)
        for sequence in [0, 2, 3, 4, 5, 6, 7] as [UInt16] {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await sink.waitForFrames(4)
        await loop.stop()
        // -1 is the concealment frame, in sequence 1's own slot.
        #expect(await sink.recorded() == [[0, 0], [-1, -1], [2, 2], [3, 3]])
        #expect(await decoder.concealedSSRCs == [11])
    }

    @Test("A duplicated packet is rejected instead of played twice")
    func duplicateIsRejected() async throws {
        let transport = ReceiveTransportDouble()
        let sink = PlaybackSinkDouble()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: sink,
            clock: ManualReceiveClock()
        )
        try await loop.start(generation: 1)
        for sequence in [0, 1, 2, 1, 3, 4, 5, 6, 7] as [UInt16] {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await sink.waitForFrames(4)
        await loop.stop()
        #expect(await sink.recorded() == [[0, 0], [1, 1], [2, 2], [3, 3]])
    }

    @Test("Playback order survives the 16-bit sequence wraparound")
    func wraparoundPreservesPlaybackOrder() async throws {
        let transport = ReceiveTransportDouble()
        let sink = PlaybackSinkDouble()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: sink,
            clock: ManualReceiveClock()
        )
        try await loop.start(generation: 1)
        for sequence in [65_532, 65_533, 65_534, 65_535, 0, 1, 2, 3] as [UInt16] {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await sink.waitForFrames(4)
        await loop.stop()
        // Int16(truncatingIfNeeded:) of 65532...65535 is -4...-1.
        #expect(await sink.recorded() == [[-4, -4], [-3, -3], [-2, -2], [-1, -1]])
    }

    @Test("Two overlapping speakers are mixed with a saturating clipping guard")
    func overlappingSpeakersAreMixedWithSaturation() async throws {
        let transport = ReceiveTransportDouble()
        let sink = PlaybackSinkDouble()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: sink,
            clock: ManualReceiveClock()
        )
        try await loop.start(generation: 1)
        // Sequence 32767 decodes to Int16.max in this double, so two speakers
        // overlapping at that sequence would wrap to -2 under `&+`.
        let sequences: [UInt16] = [32_767, 32_768, 32_769, 32_770, 32_771, 32_772]
        for sequence in sequences {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 22))
        }
        await sink.waitForFrames(2)
        await loop.stop()
        let played = await sink.recorded()
        #expect(played.first == [Int16.max, Int16.max])
        #expect(await loop.snapshot().activeStreamCount == 0, "stop clears stream state")
    }

    @Test("A payload type this layer does not decode is ignored, never terminal")
    func unexpectedPayloadTypeIsIgnored() async throws {
        let transport = ReceiveTransportDouble()
        let sink = PlaybackSinkDouble()
        let terminal = TerminalRecorder()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: sink,
            clock: ManualReceiveClock()
        )
        await loop.setTerminalHandler { await terminal.record() }
        try await loop.start(generation: 1)
        // 102 is an RTX payload type the RTP header validator rejects outright;
        // 103 is a negotiated video payload type this audio layer skips. Both
        // ride the same socket as audio on a real call.
        await transport.enqueue(makeRTPPacket(payloadType: 102, sequence: 0, ssrc: 99))
        await transport.enqueue(
            makeRTPPacket(
                payloadType: DiscordVoiceRTPHeader.discordVideoVP8PayloadType,
                sequence: 1,
                ssrc: 99
            )
        )
        for sequence in UInt16(0)...UInt16(5) {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await sink.waitForFrames(2)
        let snapshot = await loop.snapshot()
        await loop.stop()
        #expect(snapshot.phase == .receiving)
        #expect(snapshot.ignoredPacketCount == 2)
        #expect(await terminal.count == 0)
        #expect(await sink.recorded() == [[0, 0], [1, 1]])
    }

    @Test("Malformed RTP framing ends the loop through the terminal handler")
    func malformedFramingIsTerminal() async throws {
        let transport = ReceiveTransportDouble()
        let terminal = TerminalRecorder()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: PlaybackSinkDouble(),
            clock: ManualReceiveClock()
        )
        await loop.setTerminalHandler { await terminal.record() }
        try await loop.start(generation: 1)
        // Truncated below the 12-byte base header.
        await transport.enqueue([0x80, 0x78, 0x00])
        await terminal.wait()
        #expect(await loop.snapshot().phase == .failed)
        await loop.stop()
    }

    @Test("A terminal transport error ends the loop through the terminal handler")
    func transportFailureIsTerminal() async throws {
        let transport = ReceiveTransportDouble()
        let terminal = TerminalRecorder()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: PlaybackSinkDouble(),
            clock: ManualReceiveClock()
        )
        await loop.setTerminalHandler { await terminal.record() }
        try await loop.start(generation: 1)
        await transport.enqueueFailure()
        await terminal.wait()
        #expect(await loop.snapshot().phase == .failed)
        await loop.stop()
    }

    @Test("A packet the media plane refuses is dropped and counted, not terminal")
    func decodeFailureFailsClosedWithoutTerminating() async throws {
        let transport = ReceiveTransportDouble()
        let decoder = ReceiveDecoderDouble()
        let sink = PlaybackSinkDouble()
        let terminal = TerminalRecorder()
        let loop = try makeLoop(
            transport: transport,
            decoder: decoder,
            sink: sink,
            clock: ManualReceiveClock()
        )
        await loop.setTerminalHandler { await terminal.record() }
        await decoder.failPacketsTagged(0xEE)
        try await loop.start(generation: 1)
        for sequence in UInt16(0)...UInt16(7) {
            await transport.enqueue(
                makeRTPPacket(sequence: sequence, ssrc: 11, tag: sequence == 1 ? 0xEE : 0)
            )
        }
        await sink.waitForFrames(3)
        let snapshot = await loop.snapshot()
        await loop.stop()
        #expect(await terminal.count == 0)
        #expect(snapshot.phase == .receiving)
        #expect(snapshot.droppedPacketCount == 1)
        // The refused packet yields no audio at all; the stream continues.
        #expect(await sink.recorded() == [[0, 0], [2, 2], [3, 3]])
    }

    @Test("A frame the plane attributes to another SSRC is dropped, not misrouted")
    func mismatchedSSRCAttributionIsDropped() async throws {
        let transport = ReceiveTransportDouble()
        let decoder = ReceiveDecoderDouble()
        let sink = PlaybackSinkDouble()
        let loop = try makeLoop(
            transport: transport,
            decoder: decoder,
            sink: sink,
            clock: ManualReceiveClock()
        )
        await decoder.attributeEverythingTo(ssrc: 4_242)
        try await loop.start(generation: 1)
        for sequence in UInt16(0)...UInt16(7) {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        // Nothing can ever play; wait on the drop counter reaching the releases.
        while await loop.snapshot().droppedPacketCount < 4 {
            await Task.yield()
        }
        await loop.stop()
        #expect(await sink.recorded().isEmpty)
    }

    @Test("A playback failure ends the loop through the terminal handler")
    func playbackFailureIsTerminal() async throws {
        let transport = ReceiveTransportDouble()
        let sink = PlaybackSinkDouble()
        let terminal = TerminalRecorder()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: sink,
            clock: ManualReceiveClock()
        )
        await sink.failFromFrame(0)
        await loop.setTerminalHandler { await terminal.record() }
        try await loop.start(generation: 1)
        for sequence in UInt16(0)...UInt16(5) {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await terminal.wait()
        #expect(await loop.snapshot().phase == .failed)
        await loop.stop()
    }

    /// Ordered teardown: `stop()` must drain the pump before returning, so the
    /// owner can reset the media plane with no packet in flight. The transport
    /// double parks in a cancellation-aware receive, exactly like the real UDP
    /// session, so a `stop()` that failed to cancel would hang this test rather
    /// than fail it.
    @Test("stop() drains the pump and never reports a terminal failure")
    func orderedTeardownDrainsPump() async throws {
        let transport = ReceiveTransportDouble()
        let sink = PlaybackSinkDouble()
        let terminal = TerminalRecorder()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: sink,
            clock: ManualReceiveClock()
        )
        await loop.setTerminalHandler { await terminal.record() }
        try await loop.start(generation: 1)
        for sequence in UInt16(0)...UInt16(5) {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await sink.waitForFrames(2)
        await loop.stop()

        let callsAtStop = await transport.receiveCallCount
        #expect(await loop.snapshot().phase == .stopped)
        #expect(await terminal.count == 0, "a deliberate stop is not a terminal failure")

        // Nothing may be consumed after stop() returned.
        for sequence in UInt16(6)...UInt16(20) {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await Task.yield()
        #expect(await transport.receiveCallCount == callsAtStop)
        #expect(await sink.recorded().count == 2)
    }

    @Test("Idle streams are evicted on the injected clock, never a wall clock")
    func idleStreamsAreEvicted() async throws {
        let transport = ReceiveTransportDouble()
        let sink = PlaybackSinkDouble()
        let clock = ManualReceiveClock()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: sink,
            clock: clock,
            idleTimeout: .seconds(5)
        )
        try await loop.start(generation: 1)
        for sequence in UInt16(0)...UInt16(5) {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 11))
        }
        await sink.waitForFrames(2)
        #expect(await loop.snapshot().activeStreamCount == 1)

        // Speaker 11 goes quiet; time passes only because the test says so.
        clock.advance(by: .seconds(6))
        for sequence in UInt16(0)...UInt16(5) {
            await transport.enqueue(makeRTPPacket(sequence: sequence, ssrc: 22))
        }
        await sink.waitForFrames(4)
        let snapshot = await loop.snapshot()
        await loop.stop()
        #expect(snapshot.activeStreamCount == 1, "the idle speaker's state must be gone")
        #expect(snapshot.evictedStreamCount == 1)
    }

    @Test("Concurrent per-SSRC state is capped, so an SSRC spray cannot grow memory")
    func concurrentStreamsAreCapped() async throws {
        let transport = ReceiveTransportDouble()
        let sink = PlaybackSinkDouble()
        let loop = try makeLoop(
            transport: transport,
            decoder: ReceiveDecoderDouble(),
            sink: sink,
            clock: ManualReceiveClock(),
            maximumStreams: 2
        )
        try await loop.start(generation: 1)
        for ssrc in UInt32(1)...UInt32(20) {
            await transport.enqueue(makeRTPPacket(sequence: 0, ssrc: ssrc))
        }
        while await loop.snapshot().receivedPacketCount < 20 {
            await Task.yield()
        }
        let snapshot = await loop.snapshot()
        await loop.stop()
        #expect(snapshot.activeStreamCount == 2)
        #expect(snapshot.rejectedStreamCount == 18)
    }
}
