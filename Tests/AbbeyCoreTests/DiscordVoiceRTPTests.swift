import Testing
@testable import AbbeyCore

@Suite("Discord Voice RTP")
struct DiscordVoiceRTPTests {
    @Test("RTP headers round trip CSRCs and word-padded extensions")
    func headerRoundTrip() throws {
        let codec = try DiscordVoiceRTPCodec()
        let extensionData: [UInt8] = [0xbe, 0xde, 0x01, 0x10, 0xaa, 0xbb, 0x00, 0x00]
        let headerExtension = try DiscordVoiceRTPHeaderExtension(
            profile: 0x1000,
            data: extensionData
        )
        let header = try DiscordVoiceRTPHeader(
            marker: true,
            hasPadding: false,
            sequence: 0xfffe,
            timestamp: 0x0102_0304,
            ssrc: 0xa0b0_c0d0,
            csrcs: [1, 0xffff_ffff],
            headerExtension: headerExtension
        )

        let encoded = try codec.encode(header)

        #expect(encoded.count == 32)
        #expect(encoded[0] == 0x92)
        #expect(encoded[1] == 0xf8)
        #expect(try codec.unencryptedHeaderLength(in: encoded) == encoded.count)
        #expect(try codec.decodeHeader(from: encoded) == header)
    }

    @Test("Base header encoding is network byte order and uses Discord payload type")
    func baseHeaderEncoding() throws {
        let codec = try DiscordVoiceRTPCodec()
        let header = try DiscordVoiceRTPHeader(
            sequence: 0x1234,
            timestamp: 0x5678_9abc,
            ssrc: 0xdef0_1122
        )

        #expect(try codec.encode(header) == [
            0x80, 0x78, 0x12, 0x34,
            0x56, 0x78, 0x9a, 0xbc,
            0xde, 0xf0, 0x11, 0x22,
        ])
    }

    @Test("Clear header length and protected layout do not inspect protected bytes")
    func protectedLayoutIsOpaque() throws {
        let codec = try DiscordVoiceRTPCodec()
        let extensionData = try DiscordVoiceRTPHeaderExtension(
            profile: 0xbede,
            data: [0x10, 0x01, 0x00, 0x00]
        )
        let header = try DiscordVoiceRTPHeader(
            hasPadding: true,
            sequence: 1,
            timestamp: 2,
            ssrc: 3,
            headerExtension: extensionData
        )
        var packet = try codec.encode(header)
        let headerLength = packet.count
        packet += [0x00, 0xff, 0x00, 0x00, 0x12, 0x34, 0x56, 0x78]

        #expect(try codec.unencryptedHeaderLength(in: packet) == headerLength)
        #expect(
            try codec.protectedLayout(in: packet, trailingByteCount: 4)
                == DiscordVoiceRTPProtectedLayout(
                    headerRange: 0..<headerLength,
                    protectedPayloadRange: headerLength..<(packet.count - 4),
                    trailingRange: (packet.count - 4)..<packet.count
                )
        )
    }

    @Test("Plaintext layout validates RTP padding")
    func plaintextPadding() throws {
        let codec = try DiscordVoiceRTPCodec()
        let header = try DiscordVoiceRTPHeader(
            hasPadding: true,
            sequence: 1,
            timestamp: 2,
            ssrc: 3
        )
        var packet = try codec.encode(header)
        let headerLength = packet.count
        packet += [0xaa, 0xbb, 0x00, 0x00, 0x00, 0x04]

        #expect(
            try codec.plaintextLayout(in: packet)
                == DiscordVoiceRTPPlaintextLayout(
                    headerRange: 0..<headerLength,
                    payloadRange: headerLength..<(headerLength + 2),
                    paddingRange: (headerLength + 2)..<packet.count
                )
        )

        var zeroPadding = try codec.encode(header)
        zeroPadding += [0xaa, 0x00]
        do {
            _ = try codec.plaintextLayout(in: zeroPadding)
            Issue.record("Expected zero RTP padding to be rejected")
        } catch let error as DiscordVoiceRTPError {
            #expect(error == .invalidPaddingCount(0))
        }

        do {
            _ = try codec.plaintextLayout(in: try codec.encode(header))
            Issue.record("Expected a set padding flag without payload to be rejected")
        } catch let error as DiscordVoiceRTPError {
            #expect(error == .missingPadding)
        }
    }

    @Test("Malformed and oversized headers fail with bounded errors")
    func malformedHeaders() throws {
        let codec = try DiscordVoiceRTPCodec(maximumPacketSize: 32)
        let valid = try codec.encode(
            try DiscordVoiceRTPHeader(sequence: 1, timestamp: 2, ssrc: 3)
        )

        let cases: [([UInt8], DiscordVoiceRTPError)] = [
            (Array(valid.prefix(11)), .packetTooShort(minimum: 12, actual: 11)),
            ([0x40] + Array(valid.dropFirst()), .unsupportedVersion(1)),
            ([valid[0], 0x79] + Array(valid.dropFirst(2)), .unexpectedPayloadType(0x79)),
            ([0x81] + Array(valid.dropFirst()), .truncatedCSRCList(expectedHeaderBytes: 16, actualPacketBytes: 12)),
            ([0x90] + Array(valid.dropFirst()), .truncatedExtensionPreamble),
            (
                [0x90] + Array(valid.dropFirst()) + [0xbe, 0xde, 0x00, 0x02, 1, 2, 3, 4],
                .truncatedExtensionData(expectedHeaderBytes: 24, actualPacketBytes: 20)
            ),
            (valid + Array(repeating: 0, count: 21), .packetTooLarge(maximum: 32, actual: 33)),
        ]

        for (packet, expectedError) in cases {
            do {
                _ = try codec.unencryptedHeaderLength(in: packet)
                Issue.record("Expected malformed RTP packet to be rejected")
            } catch let error as DiscordVoiceRTPError {
                #expect(error == expectedError)
            }
        }
    }

    @Test("Extension model enforces 32-bit word alignment")
    func extensionAlignment() throws {
        for length in [1, 2, 3, 5, 6, 7] {
            do {
                _ = try DiscordVoiceRTPHeaderExtension(
                    profile: 0xbede,
                    data: Array(repeating: 0, count: length)
                )
                Issue.record("Expected non-word-aligned extension data to fail")
            } catch let error as DiscordVoiceRTPError {
                #expect(error == .extensionDataNotWordAligned(length))
            }
        }
    }

    @Test("Sequence and timestamp clocks wrap deterministically")
    func clockWraps() throws {
        var clock = try DiscordVoiceRTPClock(
            initialSequence: UInt16.max - 1,
            initialTimestamp: UInt32.max - 1_000
        )

        #expect(clock.next() == .init(sequence: 65_534, timestamp: 4_294_966_295))
        #expect(clock.next() == .init(sequence: 65_535, timestamp: 4_294_967_255))
        #expect(clock.next() == .init(sequence: 0, timestamp: 919))
        #expect(clock.sequence == 1)
        #expect(clock.timestamp == 1_879)

        var shortFrameClock = try DiscordVoiceRTPClock(
            initialSequence: 10,
            initialTimestamp: 20,
            samplesPerFrame: 120
        )
        for expectedSequence in UInt16(10)..<UInt16(110) {
            let tick = shortFrameClock.next()
            #expect(tick.sequence == expectedSequence)
        }
        #expect(shortFrameClock.timestamp == 12_020)
    }

    @Test("Replay window accepts reordering, rejects replay, and crosses wrap")
    func replayWindowBehavior() throws {
        var window = try DiscordVoiceRTPReplayWindow(windowSize: 8, maximumForwardJump: 32)

        #expect(window.observe(65_534) == .acceptedFirst)
        #expect(window.observe(0) == .acceptedNewHighest(distance: 2))
        #expect(window.observe(65_535) == .acceptedReordered(distanceBehind: 1))
        #expect(window.observe(65_535) == .duplicate(distanceBehind: 1))
        #expect(window.observe(65_534) == .duplicate(distanceBehind: 2))
        #expect(window.observe(65_528) == .tooOld(distanceBehind: 8))
        #expect(window.observe(40) == .tooFarAhead(distance: 40))
        #expect(window.highestSequence == 0)
        #expect(window.observe(1) == .acceptedNewHighest(distance: 1))
    }

    @Test("Replay window remains bounded over repeated sequence wrap")
    func replayWindowWrapProperty() throws {
        var window = try DiscordVoiceRTPReplayWindow(windowSize: 64, maximumForwardJump: 1)
        var sequence = UInt16.max - 128

        #expect(window.observe(sequence) == .acceptedFirst)
        for _ in 0..<1_024 {
            sequence &+= 1
            #expect(window.observe(sequence) == .acceptedNewHighest(distance: 1))
            #expect(window.observe(sequence) == .duplicate(distanceBehind: 0))
        }
        #expect(window.highestSequence == sequence)
    }

    @Test("SSRC mapping is bounded and supports multiple media sources per user")
    func sourceMapping() throws {
        var mappings = try DiscordVoiceRTPSourceMap(capacity: 2)
        try mappings.upsert(.init(ssrc: 20, userID: "user", mediaKind: .screen))
        try mappings.upsert(.init(ssrc: 10, userID: "user", mediaKind: .audio))

        #expect(mappings.count == 2)
        #expect(mappings[ssrc: 10]?.mediaKind == .audio)
        #expect(mappings.sources(for: "user").map(\.ssrc) == [10, 20])

        try mappings.upsert(.init(ssrc: 10, userID: "updated", mediaKind: .audio))
        #expect(mappings[ssrc: 10]?.userID == "updated")

        do {
            try mappings.upsert(.init(ssrc: 30, userID: "third"))
            Issue.record("Expected bounded SSRC map to reject a third source")
        } catch let error as DiscordVoiceRTPError {
            #expect(error == .mappingCapacityExceeded(2))
        }

        #expect(mappings.remove(ssrc: 20)?.mediaKind == .screen)
        try mappings.upsert(.init(ssrc: 30, userID: "third"))
        #expect(mappings.count == 2)
    }
}
