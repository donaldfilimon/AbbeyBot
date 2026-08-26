import Testing
@testable import AbbeyCore

@Suite("Discord H.264 RFC 6184")
struct DiscordVoiceH264RTPTests {
    @Test func goldenSingleNALAndFUAFragmentsRoundTrip() throws {
        let accessUnit: [UInt8] = [
            0, 0, 0, 1, 0x67, 0x42,
            0, 0, 1, 0x65, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
        ]
        let packetizer = try DiscordVoiceH264Packetizer(pathMTU: 40)
        var clock = try DiscordVoiceVideoRTPClock(
            initialSequence: 10,
            initialTimestamp: 90_000,
            ticksPerFrame: 3_000
        )
        let packets = try packetizer.packetize(
            annexB: accessUnit,
            payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
            ssrc: 77,
            clock: &clock
        )

        #expect(packets.count == 3)
        #expect(packets.map(\.header.sequence) == [10, 11, 12])
        #expect(packets.allSatisfy { $0.header.timestamp == 90_000 })
        #expect(packets.map(\.header.marker) == [false, false, true])
        #expect(packets[0].payload == [0x67, 0x42])
        #expect(packets[1].payload == [0x7c, 0x85, 1, 2, 3, 4, 5, 6])
        #expect(packets[2].payload == [0x7c, 0x45, 7, 8, 9, 10, 11, 12])
        #expect(clock.sequence == 13)
        #expect(clock.timestamp == 93_000)

        var depacketizer = DiscordVoiceH264Depacketizer()
        #expect(try depacketizer.insert(packets[0]) == nil)
        #expect(try depacketizer.insert(packets[1]) == nil)
        #expect(try depacketizer.insert(packets[2]) == [
            0, 0, 0, 1, 0x67, 0x42,
            0, 0, 0, 1, 0x65, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
        ])
    }

    @Test func lossAndReorderFailClosedWithExactMissingSequence() throws {
        let packetizer = try DiscordVoiceH264Packetizer(pathMTU: 40)
        var clock = try DiscordVoiceVideoRTPClock(initialSequence: 100, initialTimestamp: 1)
        let packets = try packetizer.packetize(
            annexB: [0, 0, 0, 1, 0x65] + Array(0..<20),
            payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
            ssrc: 9,
            clock: &clock
        )
        #expect(packets.count > 2)
        var depacketizer = DiscordVoiceH264Depacketizer()
        #expect(try depacketizer.insert(packets[0]) == nil)
        #expect(throws: DiscordVoiceH264RTPError.sequenceGap(expected: 101, actual: 102)) {
            _ = try depacketizer.insert(packets[2])
        }
    }

    @Test func malformedOrUnknownPacketizationCasesFailClosed() throws {
        let packetizer = try DiscordVoiceH264Packetizer()
        var clock = try DiscordVoiceVideoRTPClock(initialSequence: 0, initialTimestamp: 0)
        #expect(throws: DiscordVoiceH264RTPError.emptyAccessUnit) {
            _ = try packetizer.packetize(annexB: [], payloadType: 101, ssrc: 1, clock: &clock)
        }
        #expect(throws: DiscordVoiceH264RTPError.malformedAnnexB) {
            _ = try packetizer.packetize(annexB: [0x65, 1], payloadType: 101, ssrc: 1, clock: &clock)
        }
        #expect(throws: DiscordVoiceH264RTPError.invalidNALUnit) {
            _ = try packetizer.packetize(
                annexB: [0, 0, 0, 1, 0x7c, 1],
                payloadType: 101,
                ssrc: 1,
                clock: &clock
            )
        }
        #expect(throws: DiscordVoiceH264RTPError.invalidNALUnit) {
            _ = try packetizer.packetize(
                // RFC 6184 requires forbidden_zero_bit to remain zero even
                // when the low five bits name an otherwise valid NAL type.
                annexB: [0, 0, 0, 1, 0xe5, 1],
                payloadType: 101,
                ssrc: 1,
                clock: &clock
            )
        }

        var depacketizer = DiscordVoiceH264Depacketizer()
        let invalidSingleFragment = DiscordVoiceVideoRTPFragment(
            header: try DiscordVoiceRTPHeader(
                marker: true,
                payloadType: 101,
                sequence: 1,
                timestamp: 1,
                ssrc: 1
            ),
            payload: [0x7c, 0xc5, 1]
        )
        #expect(throws: DiscordVoiceH264RTPError.invalidNALUnit) {
            _ = try depacketizer.insert(invalidSingleFragment)
        }

        let forbiddenSingleNAL = DiscordVoiceVideoRTPFragment(
            header: try DiscordVoiceRTPHeader(
                marker: true,
                payloadType: 101,
                sequence: 2,
                timestamp: 2,
                ssrc: 1
            ),
            payload: [0xe5, 1]
        )
        #expect(throws: DiscordVoiceH264RTPError.invalidNALUnit) {
            _ = try depacketizer.insert(forbiddenSingleNAL)
        }

        let forbiddenFUA = DiscordVoiceVideoRTPFragment(
            header: try DiscordVoiceRTPHeader(
                marker: false,
                payloadType: 101,
                sequence: 3,
                timestamp: 3,
                ssrc: 1
            ),
            payload: [0xfc, 0x85, 1]
        )
        #expect(throws: DiscordVoiceH264RTPError.invalidNALUnit) {
            _ = try depacketizer.insert(forbiddenFUA)
        }

        let oversized = [UInt8](repeating: 0, count: 4 * 1_024 * 1_024 + 1)
        #expect(throws: DiscordVoiceH264RTPError.accessUnitTooLarge(
            actual: oversized.count,
            maximum: 4 * 1_024 * 1_024
        )) {
            _ = try DiscordVoiceH264Packetizer.nalUnits(in: oversized)
        }
    }

    @Test func boundedReorderReportsNACKGapAndAcceptsRTXRecovery() throws {
        let packetizer = try DiscordVoiceH264Packetizer(pathMTU: 40)
        var clock = try DiscordVoiceVideoRTPClock(initialSequence: 200, initialTimestamp: 9_000)
        let packets = try packetizer.packetize(
            annexB: [0, 0, 0, 1, 0x65] + Array(0..<28),
            payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
            ssrc: 44,
            clock: &clock
        )
        #expect(packets.count >= 4)

        var reorder = try DiscordVoiceH264ReorderBuffer(capacity: 16)
        #expect(try reorder.insert(packets[0]).contiguous.map(\.header.sequence) == [200])
        let outOfOrder = try reorder.insert(packets[2])
        #expect(outOfOrder.contiguous.isEmpty)
        #expect(outOfOrder.missingSequences == [201])

        let restored = try DiscordVoiceH264RTX().restore(
            authenticatedRTXPayload: [0, 201] + packets[1].payload,
            timestamp: packets[1].header.timestamp,
            primarySSRC: packets[1].header.ssrc,
            marker: packets[1].header.marker
        )
        let recovered = try reorder.insert(restored)
        #expect(recovered.contiguous.map(\.header.sequence) == [201, 202])
        #expect(recovered.missingSequences.isEmpty)
        #expect(try reorder.insert(restored).duplicateDropped)
    }

    @Test func reorderWindowHandlesSequenceWrapAndRejectsUnboundedJump() throws {
        func packet(_ sequence: UInt16) throws -> DiscordVoiceVideoRTPFragment {
            .init(
                header: try DiscordVoiceRTPHeader(
                    payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType,
                    sequence: sequence,
                    timestamp: 1,
                    ssrc: 1
                ),
                payload: [0x61, 1]
            )
        }
        var buffer = try DiscordVoiceH264ReorderBuffer(capacity: 8)
        #expect(try buffer.insert(packet(UInt16.max)).contiguous.count == 1)
        #expect(try buffer.insert(packet(1)).missingSequences == [0])
        #expect(try buffer.insert(packet(0)).contiguous.map(\.header.sequence) == [0, 1])
        #expect(throws: DiscordVoiceH264RTPError.reorderWindowExceeded) {
            _ = try buffer.insert(packet(20))
        }
    }
}
