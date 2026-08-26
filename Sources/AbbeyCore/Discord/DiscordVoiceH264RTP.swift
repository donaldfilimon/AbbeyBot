import Foundation

public enum DiscordVoiceH264RTPError: Error, Equatable, Sendable {
    case emptyAccessUnit
    case malformedAnnexB
    case invalidNALUnit
    case fragmentBudgetTooSmall
    case incompleteFragment
    case accessUnitTooLarge(actual: Int, maximum: Int)
    case reorderWindowExceeded
    case invalidRTXPayload
    case sequenceGap(expected: UInt16, actual: UInt16)
}

/// RFC 6184 packetization for one Annex-B H.264 access unit. DAVE protection
/// happens before this boundary, so its codec-aware transformed frame is what
/// is split into single-NAL or FU-A RTP payloads.
public struct DiscordVoiceH264Packetizer: Sendable {
    public static let maximumAccessUnitBytes = 4 * 1_024 * 1_024
    private let transport: DiscordVoiceVideoPacketizer

    public init(
        pathMTU: Int = DiscordVoiceVideoPacketizer.defaultPathMTU,
        headerByteCount: Int = DiscordVoiceRTPHeader.baseLength,
        transportOverhead: Int = DiscordVoiceVideoPacketizer.transportAEADOverhead,
        maximumFragmentsPerFrame: Int = DiscordVoiceVideoPacketizer.defaultMaximumFragmentsPerFrame
    ) throws {
        transport = try DiscordVoiceVideoPacketizer(
            pathMTU: pathMTU,
            headerByteCount: headerByteCount,
            transportOverhead: transportOverhead,
            maximumFragmentsPerFrame: maximumFragmentsPerFrame
        )
    }

    public func packetize(
        annexB accessUnit: [UInt8],
        payloadType: UInt8,
        ssrc: UInt32,
        clock: inout DiscordVoiceVideoRTPClock
    ) throws -> [DiscordVoiceVideoRTPFragment] {
        let units = try Self.nalUnits(in: accessUnit)
        let budget = transport.maximumFragmentByteCount
        guard budget >= 3 else { throw DiscordVoiceH264RTPError.fragmentBudgetTooSmall }

        var payloads: [[UInt8]] = []
        for unit in units {
            guard let header = unit.first,
                  header & 0x80 == 0,
                  (1...23).contains(header & 0x1f)
            else {
                throw DiscordVoiceH264RTPError.invalidNALUnit
            }
            if unit.count <= budget {
                payloads.append(unit)
                continue
            }

            let fragmentBudget = budget - 2
            let nalType = header & 0x1f
            let fuIndicator = (header & 0xe0) | 28
            let body = Array(unit.dropFirst())
            var offset = 0
            while offset < body.count {
                let count = min(fragmentBudget, body.count - offset)
                let start = offset == 0
                let end = offset + count == body.count
                let fuHeader = (start ? UInt8(0x80) : 0) | (end ? UInt8(0x40) : 0) | nalType
                payloads.append([fuIndicator, fuHeader] + body[offset..<(offset + count)])
                offset += count
            }
        }

        guard payloads.count <= transport.maximumFragmentsPerFrame else {
            throw DiscordVoiceVideoPacketizationError.frameTooLarge(
                fragments: payloads.count,
                maximumFragments: transport.maximumFragmentsPerFrame
            )
        }
        let tick = try clock.nextFrame(fragmentCount: payloads.count)
        return try payloads.enumerated().map { index, payload in
            DiscordVoiceVideoRTPFragment(
                header: try DiscordVoiceRTPHeader(
                    marker: index == payloads.count - 1,
                    payloadType: payloadType,
                    sequence: tick.sequence &+ UInt16(index),
                    timestamp: tick.timestamp,
                    ssrc: ssrc
                ),
                payload: payload
            )
        }
    }

    public static func nalUnits(in bytes: [UInt8]) throws -> [[UInt8]] {
        guard !bytes.isEmpty else { throw DiscordVoiceH264RTPError.emptyAccessUnit }
        guard bytes.count <= maximumAccessUnitBytes else {
            throw DiscordVoiceH264RTPError.accessUnitTooLarge(
                actual: bytes.count,
                maximum: maximumAccessUnitBytes
            )
        }
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4)); index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3)); index += 3
            } else {
                index += 1
            }
        }
        guard starts.first?.offset == 0, !starts.isEmpty else {
            throw DiscordVoiceH264RTPError.malformedAnnexB
        }
        var units: [[UInt8]] = []
        for position in starts.indices {
            let begin = starts[position].offset + starts[position].length
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard begin < end else { throw DiscordVoiceH264RTPError.invalidNALUnit }
            let unit = Array(bytes[begin..<end])
            guard let header = unit.first,
                  header & 0x80 == 0,
                  (1...23).contains(header & 0x1f)
            else { throw DiscordVoiceH264RTPError.invalidNALUnit }
            units.append(unit)
        }
        return units
    }
}

/// Bounded, in-order RFC 6184 depacketizer. A sequence gap fails the access
/// unit closed and returns the exact missing sequence for an RTX/NACK layer.
public struct DiscordVoiceH264Depacketizer: Sendable {
    private var timestamp: UInt32?
    private var expectedSequence: UInt16?
    private var accessUnit: [UInt8] = []
    private var fragmentHeader: UInt8?
    private let maximumAccessUnitBytes: Int

    public init(maximumAccessUnitBytes: Int = DiscordVoiceH264Packetizer.maximumAccessUnitBytes) {
        self.maximumAccessUnitBytes = min(max(maximumAccessUnitBytes, 1_024), 16 * 1_024 * 1_024)
    }

    public mutating func insert(_ packet: DiscordVoiceVideoRTPFragment) throws -> [UInt8]? {
        if let expectedSequence, expectedSequence != packet.header.sequence {
            reset()
            throw DiscordVoiceH264RTPError.sequenceGap(expected: expectedSequence, actual: packet.header.sequence)
        }
        if let timestamp, timestamp != packet.header.timestamp {
            reset()
            throw DiscordVoiceH264RTPError.incompleteFragment
        }
        timestamp = packet.header.timestamp
        expectedSequence = packet.header.sequence &+ 1
        guard let first = packet.payload.first else { reset(); throw DiscordVoiceH264RTPError.invalidNALUnit }
        guard first & 0x80 == 0 else {
            reset()
            throw DiscordVoiceH264RTPError.invalidNALUnit
        }
        let type = first & 0x1f
        if type == 28 {
            guard packet.payload.count >= 3 else { reset(); throw DiscordVoiceH264RTPError.invalidNALUnit }
            let fuHeader = packet.payload[1]
            let isStart = fuHeader & 0x80 != 0
            let isEnd = fuHeader & 0x40 != 0
            let nalType = fuHeader & 0x1f
            guard fuHeader & 0x20 == 0,
                  !(isStart && isEnd),
                  (1...23).contains(nalType)
            else { reset(); throw DiscordVoiceH264RTPError.invalidNALUnit }
            let reconstructed = (first & 0xe0) | nalType
            if isStart {
                guard fragmentHeader == nil else { reset(); throw DiscordVoiceH264RTPError.incompleteFragment }
                appendStartCodeAnd([reconstructed])
                fragmentHeader = reconstructed
            } else {
                guard fragmentHeader == reconstructed else {
                    reset(); throw DiscordVoiceH264RTPError.incompleteFragment
                }
            }
            accessUnit.append(contentsOf: packet.payload.dropFirst(2))
            if isEnd { fragmentHeader = nil }
        } else if (1...23).contains(type) {
            guard fragmentHeader == nil else { reset(); throw DiscordVoiceH264RTPError.incompleteFragment }
            appendStartCodeAnd(packet.payload)
        } else {
            reset(); throw DiscordVoiceH264RTPError.invalidNALUnit
        }
        guard accessUnit.count <= maximumAccessUnitBytes else {
            let actual = accessUnit.count
            reset()
            throw DiscordVoiceH264RTPError.accessUnitTooLarge(
                actual: actual,
                maximum: maximumAccessUnitBytes
            )
        }
        guard packet.header.marker else { return nil }
        guard fragmentHeader == nil else { reset(); throw DiscordVoiceH264RTPError.incompleteFragment }
        let completed = accessUnit
        reset()
        return completed
    }

    private mutating func appendStartCodeAnd<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        accessUnit.append(contentsOf: [0, 0, 0, 1])
        accessUnit.append(contentsOf: bytes)
    }

    private mutating func reset() {
        timestamp = nil
        expectedSequence = nil
        accessUnit.removeAll(keepingCapacity: true)
        fragmentHeader = nil
    }
}

/// Result of one bounded reordering insertion. Contiguous packets are emitted
/// exactly once; `missingSequences` is content-free control information that a
/// caller may convert to Generic NACK feedback. No packet body is retained
/// after it is emitted or the window is reset.
public struct DiscordVoiceH264ReorderResult: Equatable, Sendable {
    public let contiguous: [DiscordVoiceVideoRTPFragment]
    public let missingSequences: [UInt16]
    public let duplicateDropped: Bool

    public init(
        contiguous: [DiscordVoiceVideoRTPFragment],
        missingSequences: [UInt16],
        duplicateDropped: Bool
    ) {
        self.contiguous = contiguous
        self.missingSequences = missingSequences
        self.duplicateDropped = duplicateDropped
    }
}

/// Small RTP sequence reorder window for H.264. It handles 16-bit wrapping,
/// rejects jumps outside its explicit bound, and reports only gaps known to be
/// bounded by a later packet. Timing/retry policy stays above this primitive.
public struct DiscordVoiceH264ReorderBuffer: Sendable {
    public let capacity: Int
    private var expected: UInt16?
    private var buffered: [UInt16: DiscordVoiceVideoRTPFragment] = [:]
    private var emitted = Set<UInt16>()

    public init(capacity: Int = 64) throws {
        guard (2...512).contains(capacity) else {
            throw DiscordVoiceH264RTPError.reorderWindowExceeded
        }
        self.capacity = capacity
        buffered.reserveCapacity(capacity)
        emitted.reserveCapacity(capacity)
    }

    public mutating func insert(_ packet: DiscordVoiceVideoRTPFragment)
        throws -> DiscordVoiceH264ReorderResult
    {
        if emitted.contains(packet.header.sequence) || buffered[packet.header.sequence] != nil {
            return .init(contiguous: [], missingSequences: currentMissing(), duplicateDropped: true)
        }
        if expected == nil { expected = packet.header.sequence }
        guard let expected else {
            throw DiscordVoiceH264RTPError.reorderWindowExceeded
        }
        let distance = Int(packet.header.sequence &- expected)
        guard distance < capacity else {
            throw DiscordVoiceH264RTPError.reorderWindowExceeded
        }
        buffered[packet.header.sequence] = packet

        var ready: [DiscordVoiceVideoRTPFragment] = []
        var cursor = expected
        while let next = buffered.removeValue(forKey: cursor) {
            ready.append(next)
            emitted.insert(cursor)
            if emitted.count > capacity {
                // Only the recent duplicate window matters; remove the oldest
                // sequence in modular distance from the new cursor.
                let newCursor = cursor &+ 1
                if let oldest = emitted.max(by: {
                    Int(newCursor &- $0) < Int(newCursor &- $1)
                }) {
                    emitted.remove(oldest)
                }
            }
            cursor &+= 1
        }
        self.expected = cursor
        return .init(
            contiguous: ready,
            missingSequences: currentMissing(),
            duplicateDropped: false
        )
    }

    public mutating func reset() {
        expected = nil
        buffered.removeAll(keepingCapacity: true)
        emitted.removeAll(keepingCapacity: true)
    }

    private func currentMissing() -> [UInt16] {
        guard let expected, !buffered.isEmpty else { return [] }
        let farthest = buffered.keys.max { lhs, rhs in
            Int(lhs &- expected) < Int(rhs &- expected)
        }!
        let distance = Int(farthest &- expected)
        guard distance > 0 else { return [] }
        return (0..<distance).compactMap { offset in
            let sequence = expected &+ UInt16(offset)
            return buffered[sequence] == nil ? sequence : nil
        }
    }
}

/// RFC 4588 RTX recovery for an already transport-authenticated payload. The
/// first two payload bytes carry the original media sequence number. The RTX
/// SSRC/payload type are deliberately not trusted: the caller supplies the
/// primary allocation that was validated by Voice Gateway state.
public struct DiscordVoiceH264RTX: Sendable {
    public init() {}

    public func restore(
        authenticatedRTXPayload: [UInt8],
        timestamp: UInt32,
        primarySSRC: UInt32,
        primaryPayloadType: UInt8 = DiscordVoiceRTPHeader.discordVideoH264PayloadType,
        marker: Bool = false
    ) throws -> DiscordVoiceVideoRTPFragment {
        guard authenticatedRTXPayload.count > 2 else {
            throw DiscordVoiceH264RTPError.invalidRTXPayload
        }
        let sequence = UInt16(authenticatedRTXPayload[0]) << 8
            | UInt16(authenticatedRTXPayload[1])
        return DiscordVoiceVideoRTPFragment(
            header: try DiscordVoiceRTPHeader(
                marker: marker,
                payloadType: primaryPayloadType,
                sequence: sequence,
                timestamp: timestamp,
                ssrc: primarySSRC
            ),
            payload: Array(authenticatedRTXPayload.dropFirst(2))
        )
    }
}
