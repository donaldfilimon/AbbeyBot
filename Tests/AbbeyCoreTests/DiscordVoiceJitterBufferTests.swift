import Testing
@testable import AbbeyCore

/// Deterministic by construction: every test drives the buffer synchronously and
/// passes time in explicitly. No wall clock, no sleeps, no concurrency.
@Suite("Discord Voice jitter buffer, PLC, and mixing")
struct DiscordVoiceJitterBufferTests {
    private func makeBuffer(
        targetDepth: Int = 4,
        maximumConcealedFrames: Int = 4,
        now: Duration = .zero
    ) throws -> DiscordVoiceStreamJitterBuffer {
        try DiscordVoiceStreamJitterBuffer(
            configuration: .init(
                targetDepth: targetDepth,
                maximumConcealedFrames: maximumConcealedFrames
            ),
            now: now
        )
    }

    private func payload(_ sequence: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence)]
    }

    /// Collapses releases to the sequence numbers, tagging concealment so a test
    /// can assert the exact interleaving of real and concealed frames.
    private func trace(_ releases: [DiscordVoiceJitterBufferRelease]) -> [String] {
        releases.map { release in
            switch release {
            case .packet(let sequence, _): "p\(sequence)"
            case .conceal(let sequence): "c\(sequence)"
            }
        }
    }

    @Test("In-order packets are released in sequence order once the buffer exceeds depth")
    func inOrderDeliveryIsSequential() throws {
        var buffer = try makeBuffer()
        var released: [String] = []
        for sequence in UInt16(0)...UInt16(7) {
            let outcome = buffer.insert(
                sequence: sequence,
                packet: payload(sequence),
                now: .zero
            )
            #expect(outcome.rejection == nil)
            released += trace(outcome.releases)
        }
        // Depth 4 holds four packets back; the rest come out oldest-first.
        #expect(released == ["p0", "p1", "p2", "p3"])
        #expect(buffer.concealedFrameCount == 0)
    }

    @Test("Reordering inside the buffer depth is repaired, not concealed")
    func reorderingWithinDepthIsRepaired() throws {
        var buffer = try makeBuffer()
        var released: [String] = []
        // 2 and 3 swap on the wire; 5 and 6 swap too.
        for sequence in [0, 1, 3, 2, 4, 6, 5, 7] as [UInt16] {
            let outcome = buffer.insert(
                sequence: sequence,
                packet: payload(sequence),
                now: .zero
            )
            #expect(outcome.rejection == nil)
            released += trace(outcome.releases)
        }
        #expect(released == ["p0", "p1", "p2", "p3"])
        #expect(buffer.concealedFrameCount == 0)
    }

    @Test("A gap that cannot be filled within the depth is concealed in its own slot")
    func gapBeyondDepthIsConcealed() throws {
        var buffer = try makeBuffer()
        var released: [String] = []
        // Sequence 1 is lost forever.
        for sequence in [0, 2, 3, 4, 5, 6, 7] as [UInt16] {
            let outcome = buffer.insert(
                sequence: sequence,
                packet: payload(sequence),
                now: .zero
            )
            released += trace(outcome.releases)
        }
        #expect(released == ["p0", "c1", "p2", "p3"])
        #expect(buffer.concealedFrameCount == 1)
    }

    @Test("A duplicate of an already-buffered packet is rejected")
    func duplicateIsRejected() throws {
        var buffer = try makeBuffer()
        for sequence in UInt16(0)...UInt16(3) {
            _ = buffer.insert(sequence: sequence, packet: payload(sequence), now: .zero)
        }
        let outcome = buffer.insert(sequence: 2, packet: payload(2), now: .zero)
        #expect(outcome.rejection == .duplicate)
        #expect(outcome.releases.isEmpty)
        #expect(buffer.rejectedPacketCount == 1)
    }

    @Test("A replayed packet whose slot was already released is rejected as late")
    func lateArrivalAfterConcealmentIsRejected() throws {
        var buffer = try makeBuffer()
        for sequence in [0, 2, 3, 4, 5, 6, 7] as [UInt16] {
            _ = buffer.insert(sequence: sequence, packet: payload(sequence), now: .zero)
        }
        // Sequence 1's slot has already been concealed and released.
        let outcome = buffer.insert(sequence: 1, packet: payload(1), now: .zero)
        #expect(outcome.rejection == .late)
        #expect(outcome.releases.isEmpty)
    }

    @Test("Far-behind and far-ahead sequence numbers are rejected without state change")
    func replayWindowBoundsAreEnforced() throws {
        var buffer = try makeBuffer()
        for sequence in UInt16(1_000)...UInt16(1_003) {
            _ = buffer.insert(sequence: sequence, packet: payload(sequence), now: .zero)
        }
        #expect(buffer.insert(sequence: 100, packet: [], now: .zero).rejection == .tooOld)
        // Forward jump beyond the replay window's maximum (4096) but still in
        // the modular "ahead" half of the space.
        #expect(buffer.insert(sequence: 6_003, packet: [], now: .zero).rejection == .tooFarAhead)
        #expect(buffer.pendingCount == 4)
    }

    /// The wraparound property this pins is the buffer's own release cursor
    /// arithmetic, not the replay window's (which has its own tests): a naive
    /// `>` comparison against the cursor drops every packet after 65535 → 0
    /// forever, and a naive `<` marks them all late.
    @Test("Delivery order survives the 16-bit sequence wraparound")
    func sequenceWraparoundPreservesDeliveryOrder() throws {
        var buffer = try makeBuffer()
        var released: [String] = []
        let wrapping: [UInt16] = [65_530, 65_531, 65_532, 65_533, 65_534, 65_535, 0, 1, 2, 3]
        for sequence in wrapping {
            let outcome = buffer.insert(
                sequence: sequence,
                packet: payload(sequence),
                now: .zero
            )
            #expect(outcome.rejection == nil, "sequence \(sequence) must not be rejected")
            released += trace(outcome.releases)
        }
        #expect(
            released == ["p65530", "p65531", "p65532", "p65533", "p65534", "p65535"]
        )
        #expect(buffer.concealedFrameCount == 0)

        // A duplicate of 65535 arriving after the wrap is still a duplicate.
        let duplicate = buffer.insert(sequence: 65_535, packet: payload(65_535), now: .zero)
        #expect(duplicate.rejection == .duplicate)

        // And a packet that reorders across the wrap is repaired, not dropped.
        var wrapped = try makeBuffer()
        var wrappedReleases: [String] = []
        for sequence in [65_534, 65_535, 1, 0, 2, 3, 4, 5] as [UInt16] {
            let outcome = wrapped.insert(
                sequence: sequence,
                packet: payload(sequence),
                now: .zero
            )
            #expect(outcome.rejection == nil, "sequence \(sequence) must not be rejected")
            wrappedReleases += trace(outcome.releases)
        }
        #expect(wrappedReleases == ["p65534", "p65535", "p0", "p1"])
        #expect(wrapped.concealedFrameCount == 0)
    }

    @Test("Pending packets stay bounded under a sender that never fills its gap")
    func pendingStaysBounded() throws {
        var buffer = try makeBuffer(targetDepth: 4)
        // Sequence 0 arrives, then 200 packets that never fill it.
        _ = buffer.insert(sequence: 0, packet: payload(0), now: .zero)
        for sequence in UInt16(2)...UInt16(200) {
            _ = buffer.insert(sequence: sequence, packet: payload(sequence), now: .zero)
            #expect(buffer.pendingCount <= 5, "pending grew past targetDepth + 1")
        }
    }

    @Test("A large forward gap resynchronizes instead of concealing every skipped slot")
    func largeGapResynchronizes() throws {
        var buffer = try makeBuffer(targetDepth: 2, maximumConcealedFrames: 2)
        _ = buffer.insert(sequence: 0, packet: payload(0), now: .zero)
        var sawResync = false
        for sequence in UInt16(500)...UInt16(510) {
            let outcome = buffer.insert(
                sequence: sequence,
                packet: payload(sequence),
                now: .zero
            )
            sawResync = sawResync || outcome.resynchronized
        }
        #expect(sawResync)
        #expect(buffer.concealedFrameCount <= 2, "concealment must not scale with the gap")
    }

    @Test("Only accepted packets refresh the stream's activity timestamp")
    func rejectedPacketsDoNotRefreshActivity() throws {
        var buffer = try makeBuffer(now: .zero)
        _ = buffer.insert(sequence: 7, packet: payload(7), now: .zero)
        _ = buffer.insert(sequence: 8, packet: payload(8), now: .milliseconds(20))
        #expect(buffer.lastActivity == .milliseconds(20))
        // A duplicate flood must not keep a dead stream alive.
        _ = buffer.insert(sequence: 8, packet: payload(8), now: .seconds(30))
        #expect(buffer.lastActivity == .milliseconds(20))
    }

    // MARK: - Mixing

    @Test("Overlapping speakers are summed with a saturating, not wrapping, guard")
    func mixSaturatesOnOverlap() {
        let loud = [Int16](repeating: .max, count: 4)
        #expect(DiscordVoiceAudioMixer.mix([loud, loud]) == loud)

        let quiet = [Int16](repeating: .min, count: 4)
        #expect(DiscordVoiceAudioMixer.mix([quiet, quiet]) == quiet)

        // Ordinary overlap still sums exactly.
        #expect(
            DiscordVoiceAudioMixer.mix([[100, -200, 300], [50, 25, -300]]) == [150, -175, 0]
        )
    }

    @Test("Mixing tolerates ragged frame lengths without truncating")
    func mixPadsShortFrames() {
        #expect(DiscordVoiceAudioMixer.mix([[1, 2, 3, 4], [10, 10]]) == [11, 12, 3, 4])
        #expect(DiscordVoiceAudioMixer.mix([]).isEmpty)
    }

    @Test("The mix queue emits once every registered stream has a frame ready")
    func mixQueueEmitsWhenAllStreamsReady() throws {
        var queue = try DiscordVoiceAudioMixQueue(maximumLag: 4)
        queue.register(ssrc: 1)
        queue.register(ssrc: 2)
        queue.append([10, 10], ssrc: 1)
        #expect(queue.drainReadyFrames().isEmpty, "one speaker alone must not emit yet")
        queue.append([5, 5], ssrc: 2)
        #expect(queue.drainReadyFrames() == [[15, 15]])
    }

    @Test("A stalled stream cannot hold playback hostage past the lag bound")
    func mixQueueEmitsWhenOneStreamLags() throws {
        var queue = try DiscordVoiceAudioMixQueue(maximumLag: 3)
        queue.register(ssrc: 1)
        queue.register(ssrc: 2)
        for _ in 0..<2 {
            queue.append([1], ssrc: 1)
        }
        #expect(queue.drainReadyFrames().isEmpty)
        queue.append([1], ssrc: 1)
        // Three frames deep with the other stream silent: emit rather than
        // stall. Exactly one frame leaves, which holds the queue at the lag
        // bound instead of dumping a burst of stale audio.
        #expect(queue.drainReadyFrames() == [[1]])
        #expect(queue.drainReadyFrames().isEmpty)
    }

    @Test("Removing a stream drops its queued frames and unblocks the rest")
    func mixQueueRemovalUnblocks() throws {
        var queue = try DiscordVoiceAudioMixQueue(maximumLag: 8)
        queue.register(ssrc: 1)
        queue.register(ssrc: 2)
        queue.append([7], ssrc: 1)
        #expect(queue.drainReadyFrames().isEmpty)
        queue.remove(ssrc: 2)
        #expect(queue.drainReadyFrames() == [[7]])
        #expect(queue.registeredStreamCount == 1)
    }
}
