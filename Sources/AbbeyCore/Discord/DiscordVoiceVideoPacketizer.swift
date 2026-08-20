// MTU-aware RTP packetization for outbound video frames.
//
// A video frame routinely exceeds the path MTU, so one frame becomes an
// ordered run of RTP packets. `DiscordVoiceVideoPacketizer` computes that run:
//
// - every fragment of a frame carries the SAME TIMESTAMP (the 90 kHz video
//   clock advances per frame, not per packet),
// - fragments carry CONTIGUOUS SEQUENCE NUMBERS in send order, and
// - the RTP MARKER BIT IS SET ONLY ON THE FINAL FRAGMENT, which is what tells
//   a receiver the frame is complete. Setting it on every packet — the
//   behavior this replaces — is wire-incorrect for any frame above MTU.
//
// WHAT THIS IS NOT. The frame is split into opaque byte ranges. This is not a
// codec-specific RTP payload format: no H.264 FU-A fragmentation unit, no VP8
// payload descriptor, no AV1 OBU aggregation header is written, and no
// receiver interoperability is claimed. This file delivers the RTP framing and
// the MTU budget only, and no video path in this repository works.

/// Failures at the video packetization boundary.
public enum DiscordVoiceVideoPacketizationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPathMTU(Int)
    case invalidHeaderByteCount(Int)
    case invalidTransportOverhead(Int)
    case invalidFragmentBound(Int)
    case mtuBudgetExhausted(pathMTU: Int, headerByteCount: Int, transportOverhead: Int)
    case emptyFrame
    case frameTooLarge(fragments: Int, maximumFragments: Int)

    public var description: String {
        switch self {
        case .invalidPathMTU(let value):
            return "Video path MTU must be positive; got \(value)"
        case .invalidHeaderByteCount(let value):
            return "Video RTP header byte count must be at least"
                + " \(DiscordVoiceRTPHeader.baseLength) and fit the path MTU; got \(value)"
        case .invalidTransportOverhead(let value):
            return "Video transport overhead must be nonnegative; got \(value)"
        case .invalidFragmentBound(let value):
            return "Video fragment bound must be in 1...\(UInt16.max); got \(value)"
        case .mtuBudgetExhausted(let pathMTU, let headerByteCount, let transportOverhead):
            return "Video path MTU \(pathMTU) leaves no payload room after \(headerByteCount)"
                + " header bytes and \(transportOverhead) transport bytes"
        case .emptyFrame:
            return "Video frame is empty"
        case .frameTooLarge(let fragments, let maximumFragments):
            return "Video frame needs \(fragments) fragments; the bound is \(maximumFragments)"
        }
    }
}

/// One RTP packet of a fragmented video frame: its clear header and the byte
/// range of the frame it carries.
public struct DiscordVoiceVideoRTPFragment: Equatable, Sendable {
    public let header: DiscordVoiceRTPHeader
    public let payload: [UInt8]

    public init(header: DiscordVoiceRTPHeader, payload: [UInt8]) {
        self.header = header
        self.payload = payload
    }

    /// The frame ends here. Equivalent to the RTP marker bit, which this
    /// packetizer sets on the final fragment and only on the final fragment.
    public var isFinalFragment: Bool { header.marker }
}

/// Splits an encoded video frame into an ordered run of RTP packets that fit
/// the path MTU after transport sealing. See the file header for what this
/// deliberately does not do.
public struct DiscordVoiceVideoPacketizer: Equatable, Sendable {
    /// The complete UDP datagram payload budget, measured **after** transport
    /// sealing: clear RTP header + ciphertext + AEAD tag + nonce counter.
    ///
    /// 1200 is the conservative WebRTC-style path MTU. The reasoning: the IPv6
    /// minimum link MTU is 1280 bytes, and an IPv6 header (40) plus a UDP
    /// header (8) costs 48, leaving 1232. Choosing 1200 keeps a 32-byte margin
    /// for a tunnel or encapsulation header on the path, so packets are not
    /// fragmented at the IP layer or silently dropped by a PMTU black hole.
    /// IPv4 (20 + 8) is strictly cheaper and therefore also covered.
    public static let defaultPathMTU = 1_200

    /// What `DiscordVoiceTransportEncryption.seal` adds to a packet: the
    /// 16-byte AEAD authentication tag plus the 4-byte big-endian nonce
    /// counter appended as the RTPSIZE trailer. The nonce itself is *not* on
    /// the wire — only its 4-byte counter prefix is — so the expansion is 20
    /// bytes for both supported transport modes. A packetizer that ignored
    /// this would emit fragments that only exceed the path MTU after sealing,
    /// which is the hardest version of this bug to see.
    public static let transportAEADOverhead =
        DiscordVoiceTransportEncryption.authenticationTagLength
            + DiscordVoiceTransportEncryption.counterSuffixLength

    /// Defensive bound on fragments per frame, in the spirit of the other
    /// bounds in this package. At the default budget it admits frames up to
    /// about 4.8 MB — far beyond any real encoded frame — while staying well
    /// inside the 16-bit RTP sequence space, so a frame can never claim more
    /// sequence numbers than exist and alias its own fragments.
    public static let defaultMaximumFragmentsPerFrame = 4_096

    public let pathMTU: Int
    public let headerByteCount: Int
    public let transportOverhead: Int
    public let maximumFragmentsPerFrame: Int

    /// - Parameters:
    ///   - pathMTU: the sealed datagram budget (see ``defaultPathMTU``).
    ///   - headerByteCount: the encoded length of the clear RTP header these
    ///     packets carry. The default is the 12-byte fixed header; a caller
    ///     adding CSRCs or a header extension must pass that header's
    ///     `encodedLength` so the budget shrinks with it.
    ///   - transportOverhead: bytes the transport adds after packetization.
    ///   - maximumFragmentsPerFrame: fail-closed bound on frame size.
    public init(
        pathMTU: Int = Self.defaultPathMTU,
        headerByteCount: Int = DiscordVoiceRTPHeader.baseLength,
        transportOverhead: Int = Self.transportAEADOverhead,
        maximumFragmentsPerFrame: Int = Self.defaultMaximumFragmentsPerFrame
    ) throws {
        guard pathMTU > 0 else {
            throw DiscordVoiceVideoPacketizationError.invalidPathMTU(pathMTU)
        }
        guard headerByteCount >= DiscordVoiceRTPHeader.baseLength,
              headerByteCount <= pathMTU
        else {
            throw DiscordVoiceVideoPacketizationError.invalidHeaderByteCount(headerByteCount)
        }
        guard transportOverhead >= 0 else {
            throw DiscordVoiceVideoPacketizationError.invalidTransportOverhead(transportOverhead)
        }
        guard (1...Int(UInt16.max)).contains(maximumFragmentsPerFrame) else {
            throw DiscordVoiceVideoPacketizationError
                .invalidFragmentBound(maximumFragmentsPerFrame)
        }
        guard pathMTU - headerByteCount - transportOverhead >= 1 else {
            throw DiscordVoiceVideoPacketizationError.mtuBudgetExhausted(
                pathMTU: pathMTU,
                headerByteCount: headerByteCount,
                transportOverhead: transportOverhead
            )
        }
        self.pathMTU = pathMTU
        self.headerByteCount = headerByteCount
        self.transportOverhead = transportOverhead
        self.maximumFragmentsPerFrame = maximumFragmentsPerFrame
    }

    /// The largest media payload one fragment may carry so that the sealed
    /// packet still fits `pathMTU`. Guaranteed positive by the initializer.
    public var maximumFragmentByteCount: Int {
        pathMTU - headerByteCount - transportOverhead
    }

    /// How many packets a frame of this size occupies, without building them.
    /// Ceiling division: a frame that is an exact multiple of the budget
    /// occupies exactly that many fragments and never a trailing empty one.
    public func fragmentCount(forFrameByteCount byteCount: Int) throws -> Int {
        guard byteCount > 0 else {
            throw DiscordVoiceVideoPacketizationError.emptyFrame
        }
        let budget = maximumFragmentByteCount
        let count = (byteCount + budget - 1) / budget
        guard count <= maximumFragmentsPerFrame else {
            throw DiscordVoiceVideoPacketizationError.frameTooLarge(
                fragments: count,
                maximumFragments: maximumFragmentsPerFrame
            )
        }
        return count
    }

    /// Fragments one encoded (and, on the real send path, already
    /// DAVE-protected) frame into an ordered run of RTP packets sharing
    /// `timestamp`, numbered from `startingSequence`, with the marker bit on
    /// the last fragment only.
    ///
    /// Fails closed on an empty frame and on a frame past the fragment bound;
    /// there is no path that emits an oversized unfragmented packet.
    public func packetize(
        frame: [UInt8],
        payloadType: UInt8,
        ssrc: UInt32,
        startingSequence: UInt16,
        timestamp: UInt32
    ) throws -> [DiscordVoiceVideoRTPFragment] {
        let count = try fragmentCount(forFrameByteCount: frame.count)
        let budget = maximumFragmentByteCount

        var fragments: [DiscordVoiceVideoRTPFragment] = []
        fragments.reserveCapacity(count)
        for index in 0..<count {
            let start = index * budget
            let end = min(start + budget, frame.count)
            let isFinalFragment = index == count - 1
            let header = try DiscordVoiceRTPHeader(
                marker: isFinalFragment,
                payloadType: payloadType,
                // `count` is bounded by the 16-bit sequence space, so this
                // conversion is exact and the wrapping add is the intended
                // RTP sequence wrap, not truncation.
                sequence: startingSequence &+ UInt16(index),
                timestamp: timestamp,
                ssrc: ssrc
            )
            fragments.append(
                DiscordVoiceVideoRTPFragment(header: header, payload: Array(frame[start..<end]))
            )
        }
        return fragments
    }

    /// Packetizes through the 90 kHz video clock, reserving one timestamp and
    /// a contiguous run of sequence numbers for the whole frame.
    ///
    /// The frame is validated *before* the clock advances, so a rejected frame
    /// never consumes RTP sequence numbers.
    public func packetize(
        frame: [UInt8],
        payloadType: UInt8,
        ssrc: UInt32,
        clock: inout DiscordVoiceVideoRTPClock
    ) throws -> [DiscordVoiceVideoRTPFragment] {
        let count = try fragmentCount(forFrameByteCount: frame.count)
        let tick = try clock.nextFrame(fragmentCount: count)
        return try packetize(
            frame: frame,
            payloadType: payloadType,
            ssrc: ssrc,
            startingSequence: tick.sequence,
            timestamp: tick.timestamp
        )
    }
}
