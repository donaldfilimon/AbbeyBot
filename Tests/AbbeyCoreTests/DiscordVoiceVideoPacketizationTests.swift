import Testing
@testable import AbbeyCore

/// Video codec negotiation and MTU-aware RTP packetization.
///
/// These are pure units. Nothing here sends, encrypts, encodes, or renders
/// video, and nothing here has run against Discord.
@Suite("Discord Voice video negotiation and packetization")
struct DiscordVoiceVideoPacketizationTests {
    // MARK: - Helpers

    private func frameBytes(_ count: Int, seed: Int = 0) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed &+ 7) }
    }

    private func expectError<E: Error & Equatable>(
        _ expected: E,
        _ label: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("Expected \(label) to be rejected, but it succeeded")
        } catch let error as E {
            #expect(error == expected, "Wrong error for \(label)")
        } catch {
            Issue.record("Unexpected error type for \(label)")
        }
    }

    // MARK: - MTU budget

    @Test("The MTU budget subtracts the RTP header and the transport AEAD expansion")
    func mtuBudgetAccountsForAEADExpansion() throws {
        // `seal` returns clear header + ciphertext + 16-byte tag + 4-byte
        // counter suffix, so sealing expands a packet by exactly 20 bytes.
        #expect(DiscordVoiceTransportEncryption.authenticationTagLength == 16)
        #expect(DiscordVoiceTransportEncryption.counterSuffixLength == 4)
        #expect(DiscordVoiceVideoPacketizer.transportAEADOverhead == 20)

        let packetizer = try DiscordVoiceVideoPacketizer()
        #expect(packetizer.pathMTU == 1_200)
        #expect(packetizer.headerByteCount == 12)
        #expect(packetizer.maximumFragmentByteCount == 1_168)

        // A larger clear header (CSRCs or an extension) shrinks the budget by
        // exactly its own size.
        let extended = try DiscordVoiceVideoPacketizer(headerByteCount: 12 + 8 + 12)
        #expect(extended.maximumFragmentByteCount == 1_168 - 20)

        expectError(
            DiscordVoiceVideoPacketizationError.mtuBudgetExhausted(
                pathMTU: 32,
                headerByteCount: 12,
                transportOverhead: 20
            ),
            "an MTU with no room for payload"
        ) {
            _ = try DiscordVoiceVideoPacketizer(pathMTU: 32)
        }
    }

    @Test("Every emitted fragment still fits the path MTU after AEAD sealing")
    func everyFragmentFitsAfterSealing() throws {
        let packetizer = try DiscordVoiceVideoPacketizer()
        let rtpCodec = try DiscordVoiceRTPCodec()
        let fragments = try packetizer.packetize(
            frame: frameBytes(9_000),
            payloadType: DiscordVoiceRTPHeader.discordVideoVP9PayloadType,
            ssrc: 0x1234_5678,
            startingSequence: 100,
            timestamp: 90_000
        )

        for fragment in fragments {
            let headerBytes = try rtpCodec.encode(fragment.header)
            let sealedSize = headerBytes.count
                + fragment.payload.count
                + DiscordVoiceVideoPacketizer.transportAEADOverhead
            #expect(sealedSize <= packetizer.pathMTU)
            #expect(!fragment.payload.isEmpty)
        }
    }

    // MARK: - Fragmentation

    @Test("A frame below the MTU is exactly one packet with the marker set")
    func subMTUFrameIsOneMarkedPacket() throws {
        let packetizer = try DiscordVoiceVideoPacketizer()
        let frame = frameBytes(700)

        let fragments = try packetizer.packetize(
            frame: frame,
            payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
            ssrc: 0xAABB_CCDD,
            startingSequence: 40,
            timestamp: 900
        )

        #expect(fragments.count == 1)
        #expect(fragments[0].header.marker)
        #expect(fragments[0].isFinalFragment)
        #expect(fragments[0].payload == frame)
        #expect(fragments[0].header.sequence == 40)
        #expect(fragments[0].header.timestamp == 900)
        #expect(fragments[0].header.ssrc == 0xAABB_CCDD)
        #expect(
            fragments[0].header.payloadType
                == DiscordVoiceRTPHeader.discordVideoH264PayloadType
        )
    }

    @Test("A frame spanning several fragments marks only the last one")
    func multiFragmentFrameMarksOnlyTheLastFragment() throws {
        let packetizer = try DiscordVoiceVideoPacketizer()
        let budget = packetizer.maximumFragmentByteCount
        let frame = frameBytes(budget * 3 + 7)

        let fragments = try packetizer.packetize(
            frame: frame,
            payloadType: DiscordVoiceRTPHeader.discordVideoAV1PayloadType,
            ssrc: 9,
            startingSequence: 1_000,
            timestamp: 270_000
        )

        #expect(fragments.count == 4)
        #expect(fragments.map(\.header.marker) == [false, false, false, true])
        #expect(fragments.map(\.payload.count) == [budget, budget, budget, 7])
        // One timestamp shared by every fragment of the frame.
        #expect(fragments.allSatisfy { $0.header.timestamp == 270_000 })
        // Contiguous sequence numbers in send order.
        #expect(fragments.map(\.header.sequence) == [1_000, 1_001, 1_002, 1_003])
        // Ordered and lossless: the fragments reassemble to the original frame.
        #expect(fragments.flatMap(\.payload) == frame)
    }

    @Test("A frame exactly one MTU budget long emits no spurious empty fragment")
    func exactBoundaryFrameEmitsOneFragment() throws {
        let packetizer = try DiscordVoiceVideoPacketizer()
        let budget = packetizer.maximumFragmentByteCount

        let exact = try packetizer.packetize(
            frame: frameBytes(budget),
            payloadType: DiscordVoiceRTPHeader.discordVideoVP8PayloadType,
            ssrc: 5,
            startingSequence: 7,
            timestamp: 3_000
        )
        #expect(exact.count == 1)
        #expect(exact[0].payload.count == budget)
        #expect(exact[0].header.marker)

        // One byte past the boundary is two fragments, the second one byte long.
        let overByOne = try packetizer.packetize(
            frame: frameBytes(budget + 1),
            payloadType: DiscordVoiceRTPHeader.discordVideoVP8PayloadType,
            ssrc: 5,
            startingSequence: 7,
            timestamp: 3_000
        )
        #expect(overByOne.count == 2)
        #expect(overByOne.map(\.payload.count) == [budget, 1])
        #expect(overByOne.map(\.header.marker) == [false, true])

        // Exactly two budgets is exactly two fragments, not three.
        let twoBudgets = try packetizer.packetize(
            frame: frameBytes(budget * 2),
            payloadType: DiscordVoiceRTPHeader.discordVideoVP8PayloadType,
            ssrc: 5,
            startingSequence: 7,
            timestamp: 3_000
        )
        #expect(twoBudgets.count == 2)
        #expect(twoBudgets.map(\.payload.count) == [budget, budget])
        #expect(twoBudgets.map(\.header.marker) == [false, true])
    }

    @Test("Fragment counts are reported without building the packets")
    func fragmentCountMatchesEmittedPackets() throws {
        let packetizer = try DiscordVoiceVideoPacketizer()
        let budget = packetizer.maximumFragmentByteCount

        for byteCount in [1, budget - 1, budget, budget + 1, budget * 2, budget * 2 + 1] {
            let predicted = try packetizer.fragmentCount(forFrameByteCount: byteCount)
            let emitted = try packetizer.packetize(
                frame: frameBytes(byteCount),
                payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
                ssrc: 1,
                startingSequence: 0,
                timestamp: 0
            )
            #expect(predicted == emitted.count, "byteCount \(byteCount)")
        }
    }

    @Test("An empty frame is rejected instead of producing an empty packet")
    func emptyFrameIsRejected() throws {
        let packetizer = try DiscordVoiceVideoPacketizer()

        expectError(DiscordVoiceVideoPacketizationError.emptyFrame, "an empty frame") {
            _ = try packetizer.packetize(
                frame: [],
                payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
                ssrc: 1,
                startingSequence: 0,
                timestamp: 0
            )
        }
        expectError(
            DiscordVoiceVideoPacketizationError.emptyFrame,
            "an empty frame's fragment count"
        ) {
            _ = try packetizer.fragmentCount(forFrameByteCount: 0)
        }

        // A rejected frame must not consume RTP sequence numbers.
        var clock = try DiscordVoiceVideoRTPClock(initialSequence: 12, initialTimestamp: 34)
        expectError(
            DiscordVoiceVideoPacketizationError.emptyFrame,
            "an empty frame packetized through the clock"
        ) {
            _ = try packetizer.packetize(
                frame: [],
                payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
                ssrc: 1,
                clock: &clock
            )
        }
        #expect(clock.sequence == 12)
        #expect(clock.timestamp == 34)
    }

    @Test("A frame past the fragment bound fails closed instead of aliasing sequence numbers")
    func oversizedFrameIsRejected() throws {
        let packetizer = try DiscordVoiceVideoPacketizer(
            pathMTU: 100,
            maximumFragmentsPerFrame: 3
        )
        let budget = packetizer.maximumFragmentByteCount
        #expect(budget == 68)

        // Three fragments is still accepted.
        let accepted = try packetizer.packetize(
            frame: frameBytes(budget * 3),
            payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
            ssrc: 1,
            startingSequence: 0,
            timestamp: 0
        )
        #expect(accepted.count == 3)

        expectError(
            DiscordVoiceVideoPacketizationError.frameTooLarge(
                fragments: 4,
                maximumFragments: 3
            ),
            "a frame needing more fragments than the bound"
        ) {
            _ = try packetizer.packetize(
                frame: frameBytes(budget * 3 + 1),
                payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
                ssrc: 1,
                startingSequence: 0,
                timestamp: 0
            )
        }

        #expect(throws: DiscordVoiceVideoPacketizationError.frameTooLarge(
            fragments: 1 + (Int.max - 1) / budget,
            maximumFragments: 3
        )) {
            _ = try packetizer.fragmentCount(forFrameByteCount: Int.max)
        }
    }

    // MARK: - Clock integration

    @Test("Packetizing through the 90 kHz clock advances by frame, not by packet")
    func clockAdvancesByFrameNotByPacket() throws {
        let packetizer = try DiscordVoiceVideoPacketizer()
        let budget = packetizer.maximumFragmentByteCount
        var clock = try DiscordVoiceVideoRTPClock(
            initialSequence: 65_534,
            initialTimestamp: 1_000,
            ticksPerFrame: 3_000
        )

        let fragments = try packetizer.packetize(
            frame: frameBytes(budget * 3),
            payloadType: DiscordVoiceRTPHeader.discordVideoVP9PayloadType,
            ssrc: 4,
            clock: &clock
        )

        #expect(fragments.count == 3)
        // The 16-bit sequence space wraps mid-frame without disturbing order.
        #expect(fragments.map(\.header.sequence) == [65_534, 65_535, 0])
        #expect(fragments.allSatisfy { $0.header.timestamp == 1_000 })
        #expect(fragments.map(\.header.marker) == [false, false, true])
        // The clock is left one past the frame's last fragment, one frame later.
        #expect(clock.sequence == 1)
        #expect(clock.timestamp == 4_000)

        let next = try packetizer.packetize(
            frame: frameBytes(10),
            payloadType: DiscordVoiceRTPHeader.discordVideoVP9PayloadType,
            ssrc: 4,
            clock: &clock
        )
        #expect(next.map(\.header.sequence) == [1])
        #expect(next[0].header.timestamp == 4_000)
    }

    @Test("A frame must occupy at least one fragment of the clock")
    func clockRejectsEmptyFrameReservation() throws {
        var clock = try DiscordVoiceVideoRTPClock(initialSequence: 1, initialTimestamp: 1)
        expectError(DiscordVoiceRTPError.invalidFragmentCount(0), "a zero-fragment frame") {
            _ = try clock.nextFrame(fragmentCount: 0)
        }
        expectError(
            DiscordVoiceRTPError.invalidFragmentCount(65_536),
            "a frame claiming more than the sequence space"
        ) {
            _ = try clock.nextFrame(fragmentCount: 65_536)
        }
        // A rejected reservation leaves the clock untouched.
        #expect(clock.sequence == 1)
        #expect(clock.timestamp == 1)
    }

    @Test("A frame claiming the whole sequence space still aliases nothing")
    func maximumFragmentReservationDoesNotAlias() throws {
        // The upper bound is exactly `UInt16.max`, not the 65536-wide space:
        // a frame of N fragments occupies base..<base+N and the next frame
        // starts at base+N, so N == 65535 leaves exactly one free slot and
        // N == 65536 would land the next frame on this frame's first
        // fragment. This pins that the boundary is where it belongs.
        let maximum = Int(UInt16.max)
        var clock = try DiscordVoiceVideoRTPClock(initialSequence: 1_000, initialTimestamp: 0)
        let tick = try clock.nextFrame(fragmentCount: maximum)
        #expect(tick.sequence == 1_000)

        var claimed = Set<UInt16>()
        for index in 0..<maximum {
            claimed.insert(1_000 &+ UInt16(index))
        }
        #expect(claimed.count == maximum)
        #expect(!claimed.contains(clock.sequence))
        #expect(clock.sequence == 1_000 &+ UInt16(maximum))
    }

    // MARK: - Codec negotiation

    @Test("A negotiated codec resolves to the payload type this client offered")
    func negotiatedCodecResolvesToOfferedPayloadType() throws {
        let negotiation = DiscordVoiceVideoCodecNegotiation.discordProposed

        let expected: [(String, DiscordVoiceVideoCodec, UInt8)] = [
            ("H264", .h264, DiscordVoiceRTPHeader.discordVideoH264PayloadType),
            ("VP8", .vp8, DiscordVoiceRTPHeader.discordVideoVP8PayloadType),
            ("VP9", .vp9, DiscordVoiceRTPHeader.discordVideoVP9PayloadType),
            ("AV1", .av1, DiscordVoiceRTPHeader.discordVideoAV1PayloadType),
        ]
        for (name, codec, payloadType) in expected {
            let resolved = try negotiation.resolve(negotiatedCodecName: name)
            #expect(resolved.codec == codec)
            #expect(resolved.payloadType == payloadType)
        }

        // Wire codec names are matched case-insensitively and whitespace-trimmed.
        #expect(try negotiation.resolve(negotiatedCodecName: "h264").codec == .h264)
        #expect(try negotiation.resolve(negotiatedCodecName: "  Vp9  ").codec == .vp9)
    }

    @Test("An absent negotiated codec fails closed instead of guessing one")
    func absentNegotiatedCodecFailsClosed() throws {
        let negotiation = DiscordVoiceVideoCodecNegotiation.discordProposed

        for name in [nil, "", "   ", "\n"] as [String?] {
            expectError(
                DiscordVoiceVideoNegotiationError.videoCodecNotNegotiated,
                "an absent negotiated codec (\(name ?? "nil"))"
            ) {
                _ = try negotiation.resolve(negotiatedCodecName: name)
            }
        }
    }

    @Test("A negotiated codec with no supported mapping fails closed")
    func unsupportedNegotiatedCodecFailsClosed() throws {
        let negotiation = DiscordVoiceVideoCodecNegotiation.discordProposed

        // H265 has no modeled Discord video payload type here, opus is an
        // audio codec, and an unknown name must never be guessed at.
        for name in ["H265", "opus", "AV2", "h.264"] {
            expectError(
                DiscordVoiceVideoNegotiationError.unsupportedNegotiatedVideoCodec(name),
                "negotiated codec \(name)"
            ) {
                _ = try negotiation.resolve(negotiatedCodecName: name)
            }
        }
    }

    @Test("A codec this client never offered is not resolvable")
    func codecOutsideTheOfferTableFailsClosed() throws {
        let h264Only = try DiscordVoiceVideoCodecNegotiation(offers: [
            DiscordVoiceVideoCodecOffer(
                codec: .h264,
                payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType
            )
        ])

        #expect(try h264Only.resolve(negotiatedCodecName: "H264").payloadType == 101)
        expectError(
            DiscordVoiceVideoNegotiationError.unsupportedNegotiatedVideoCodec("VP8"),
            "a codec outside the offer table"
        ) {
            _ = try h264Only.resolve(negotiatedCodecName: "VP8")
        }
    }

    @Test("The offer table itself is validated")
    func offerTableIsValidated() throws {
        // The compile-time default table is built through a private unchecked
        // initializer; re-run it through the throwing one so an invalid
        // constant cannot hide there.
        let rechecked = try DiscordVoiceVideoCodecNegotiation(
            offers: DiscordVoiceVideoCodecNegotiation.discordProposedOffers.map {
                try DiscordVoiceVideoCodecOffer(codec: $0.codec, payloadType: $0.payloadType)
            }
        )
        #expect(rechecked == DiscordVoiceVideoCodecNegotiation.discordProposed)
        #expect(rechecked.offers.count == DiscordVoiceVideoCodec.allCases.count)

        expectError(DiscordVoiceVideoNegotiationError.emptyCodecOffer, "an empty offer table") {
            _ = try DiscordVoiceVideoCodecNegotiation(offers: [])
        }

        expectError(
            DiscordVoiceVideoNegotiationError.duplicateCodecOffer(.vp8),
            "a repeated codec"
        ) {
            _ = try DiscordVoiceVideoCodecNegotiation(offers: [
                DiscordVoiceVideoCodecOffer(codec: .vp8, payloadType: 103),
                DiscordVoiceVideoCodecOffer(codec: .vp8, payloadType: 105),
            ])
        }

        expectError(
            DiscordVoiceVideoNegotiationError.duplicateOfferedPayloadType(103),
            "a repeated payload type"
        ) {
            _ = try DiscordVoiceVideoCodecNegotiation(offers: [
                DiscordVoiceVideoCodecOffer(codec: .vp8, payloadType: 103),
                DiscordVoiceVideoCodecOffer(codec: .vp9, payloadType: 103),
            ])
        }

        // An offer must name a payload type the RTP layer will actually build,
        // and the audio payload type is never a video offer.
        for payloadType: UInt8 in [DiscordVoiceRTPHeader.discordAudioPayloadType, 102, 200] {
            expectError(
                DiscordVoiceVideoNegotiationError.offeredPayloadTypeNotSupported(payloadType),
                "offered payload type \(payloadType)"
            ) {
                _ = try DiscordVoiceVideoCodecOffer(codec: .h264, payloadType: payloadType)
            }
        }
    }
}
