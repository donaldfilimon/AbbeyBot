/// Codec-independent RTP primitives for Discord voice media.
///
/// This module only models the clear RTP envelope. It does not encrypt, decrypt,
/// encode, or decode media payloads.
public enum DiscordVoiceRTPError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidMaximumPacketSize(Int)
    case packetTooLarge(maximum: Int, actual: Int)
    case packetTooShort(minimum: Int, actual: Int)
    case unsupportedVersion(UInt8)
    case unexpectedPayloadType(UInt8)
    case tooManyCSRCs(Int)
    case truncatedCSRCList(expectedHeaderBytes: Int, actualPacketBytes: Int)
    case extensionDataNotWordAligned(Int)
    case extensionDataTooLarge(Int)
    case truncatedExtensionPreamble
    case truncatedExtensionData(expectedHeaderBytes: Int, actualPacketBytes: Int)
    case invalidTrailingByteCount(Int)
    case trailingBytesConsumePayload
    case missingPadding
    case invalidPaddingCount(Int)
    case invalidSamplesPerFrame(UInt32)
    case invalidVideoTicksPerFrame(UInt32)
    case invalidMappingCapacity(Int)
    case mappingCapacityExceeded(Int)
    case invalidReplayWindowSize(Int)
    case invalidMaximumForwardJump(UInt16)
    case invalidFragmentCount(Int)

    public var description: String {
        switch self {
        case .invalidMaximumPacketSize(let size):
            return "RTP maximum packet size must be at least 12 bytes; got \(size)"
        case .packetTooLarge(let maximum, let actual):
            return "RTP packet exceeds the \(maximum)-byte bound; got \(actual) bytes"
        case .packetTooShort(let minimum, let actual):
            return "RTP packet is truncated; expected at least \(minimum) bytes, got \(actual)"
        case .unsupportedVersion(let version):
            return "Unsupported RTP version \(version)"
        case .unexpectedPayloadType(let payloadType):
            return "Unexpected RTP payload type \(payloadType)"
        case .tooManyCSRCs(let count):
            return "RTP permits at most 15 CSRC entries; got \(count)"
        case .truncatedCSRCList(let expected, let actual):
            return "RTP CSRC list is truncated; header requires \(expected) bytes, packet has \(actual)"
        case .extensionDataNotWordAligned(let count):
            return "RTP extension data must be padded to a 32-bit boundary; got \(count) bytes"
        case .extensionDataTooLarge(let count):
            return "RTP extension data exceeds its 16-bit word-length field; got \(count) bytes"
        case .truncatedExtensionPreamble:
            return "RTP extension preamble is truncated"
        case .truncatedExtensionData(let expected, let actual):
            return "RTP extension data is truncated; header requires \(expected) bytes, packet has \(actual)"
        case .invalidTrailingByteCount(let count):
            return "RTP trailing byte count must be nonnegative; got \(count)"
        case .trailingBytesConsumePayload:
            return "RTP trailing bytes consume the entire media payload"
        case .missingPadding:
            return "RTP padding flag is set but no padded payload is present"
        case .invalidPaddingCount(let count):
            return "RTP padding count is invalid: \(count)"
        case .invalidSamplesPerFrame(let count):
            return "RTP samples per frame must be in 1...5760; got \(count)"
        case .invalidVideoTicksPerFrame(let count):
            return "RTP video ticks per frame must be in 1...90000; got \(count)"
        case .invalidMappingCapacity(let capacity):
            return "RTP SSRC mapping capacity must be positive; got \(capacity)"
        case .mappingCapacityExceeded(let capacity):
            return "RTP SSRC mapping capacity \(capacity) was reached"
        case .invalidReplayWindowSize(let size):
            return "RTP replay window must be in 1...64; got \(size)"
        case .invalidMaximumForwardJump(let distance):
            return "RTP maximum forward jump must be in 1...32767; got \(distance)"
        case .invalidFragmentCount(let count):
            return "RTP frame must occupy at least one fragment; got \(count)"
        }
    }
}

public struct DiscordVoiceRTPHeaderExtension: Equatable, Sendable {
    public let profile: UInt16

    /// The exact extension bytes, including any zero padding required to make
    /// the data a whole number of 32-bit words.
    public let data: [UInt8]

    public init(profile: UInt16, data: [UInt8]) throws {
        guard data.count.isMultiple(of: 4) else {
            throw DiscordVoiceRTPError.extensionDataNotWordAligned(data.count)
        }
        guard data.count / 4 <= Int(UInt16.max) else {
            throw DiscordVoiceRTPError.extensionDataTooLarge(data.count)
        }
        self.profile = profile
        self.data = data
    }
}

public struct DiscordVoiceRTPHeader: Equatable, Sendable {
    public static let version: UInt8 = 2
    public static let discordAudioPayloadType: UInt8 = 0x78

    /// Client-*offered* dynamic video payload types, as used by Discord's
    /// codec negotiation per the community Voice Gateway reference
    /// (docs.discord.food, "voice-connections"). The client offers these in
    /// Select Protocol's codec list; they are the primary (non-RTX) payload
    /// types. RTX payload types are deliberately not accepted — no RTX
    /// retransmission path exists in this repository, so an RTX-marked packet
    /// fails closed at the header validation boundary.
    ///
    /// These constants name what this client *would* send for a codec; they do
    /// not select one. Selecting a payload type goes through
    /// `DiscordVoiceVideoCodecNegotiation.resolve(negotiatedCodecName:)`, which
    /// requires a codec the connection actually negotiated and fails closed
    /// otherwise. Reading a constant here directly, keyed off a codec label a
    /// caller happens to hold, skips that negotiation.
    public static let discordVideoH264PayloadType: UInt8 = 101
    public static let discordVideoVP8PayloadType: UInt8 = 103
    public static let discordVideoVP9PayloadType: UInt8 = 105
    public static let discordVideoAV1PayloadType: UInt8 = 107

    /// Every payload type this RTP layer will build or accept.
    public static let acceptedPayloadTypes: Set<UInt8> = [
        discordAudioPayloadType,
        discordVideoH264PayloadType,
        discordVideoVP8PayloadType,
        discordVideoVP9PayloadType,
        discordVideoAV1PayloadType,
    ]

    public static let baseLength = 12

    public let marker: Bool
    public let hasPadding: Bool
    public let payloadType: UInt8
    public let sequence: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let csrcs: [UInt32]
    public let headerExtension: DiscordVoiceRTPHeaderExtension?

    public init(
        marker: Bool = false,
        hasPadding: Bool = false,
        payloadType: UInt8 = Self.discordAudioPayloadType,
        sequence: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        csrcs: [UInt32] = [],
        headerExtension: DiscordVoiceRTPHeaderExtension? = nil
    ) throws {
        guard Self.acceptedPayloadTypes.contains(payloadType) else {
            throw DiscordVoiceRTPError.unexpectedPayloadType(payloadType)
        }
        guard csrcs.count <= 15 else {
            throw DiscordVoiceRTPError.tooManyCSRCs(csrcs.count)
        }
        self.marker = marker
        self.hasPadding = hasPadding
        self.payloadType = payloadType
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.csrcs = csrcs
        self.headerExtension = headerExtension
    }

    public var encodedLength: Int {
        Self.baseLength + (csrcs.count * 4) + (headerExtension.map { 4 + $0.data.count } ?? 0)
    }
}

public struct DiscordVoiceRTPProtectedLayout: Equatable, Sendable {
    public let headerRange: Range<Int>
    public let protectedPayloadRange: Range<Int>
    public let trailingRange: Range<Int>
}

public struct DiscordVoiceRTPPlaintextLayout: Equatable, Sendable {
    public let headerRange: Range<Int>
    public let payloadRange: Range<Int>
    public let paddingRange: Range<Int>
}

public struct DiscordVoiceRTPCodec: Equatable, Sendable {
    public static let defaultMaximumPacketSize = 65_535

    public let maximumPacketSize: Int

    public init(maximumPacketSize: Int = Self.defaultMaximumPacketSize) throws {
        guard maximumPacketSize >= DiscordVoiceRTPHeader.baseLength else {
            throw DiscordVoiceRTPError.invalidMaximumPacketSize(maximumPacketSize)
        }
        self.maximumPacketSize = maximumPacketSize
    }

    public func encode(_ header: DiscordVoiceRTPHeader) throws -> [UInt8] {
        let encodedLength = header.encodedLength
        guard encodedLength <= maximumPacketSize else {
            throw DiscordVoiceRTPError.packetTooLarge(maximum: maximumPacketSize, actual: encodedLength)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(encodedLength)

        var first = DiscordVoiceRTPHeader.version << 6
        if header.hasPadding { first |= 0x20 }
        if header.headerExtension != nil { first |= 0x10 }
        first |= UInt8(header.csrcs.count)
        bytes.append(first)

        var second = header.payloadType
        if header.marker { second |= 0x80 }
        bytes.append(second)
        append(header.sequence, to: &bytes)
        append(header.timestamp, to: &bytes)
        append(header.ssrc, to: &bytes)

        for csrc in header.csrcs {
            append(csrc, to: &bytes)
        }

        if let headerExtension = header.headerExtension {
            append(headerExtension.profile, to: &bytes)
            append(UInt16(headerExtension.data.count / 4), to: &bytes)
            bytes.append(contentsOf: headerExtension.data)
        }

        return bytes
    }

    /// Returns the length of the clear RTP header without inspecting media bytes.
    /// This is the boundary required by RTPSIZE transports, where the bytes after
    /// this range can remain opaque protected data.
    public func unencryptedHeaderLength(in packet: [UInt8]) throws -> Int {
        try validatePacketBounds(packet)
        try validateFixedHeader(packet)

        let csrcCount = Int(packet[0] & 0x0f)
        let csrcEnd = DiscordVoiceRTPHeader.baseLength + (csrcCount * 4)
        guard packet.count >= csrcEnd else {
            throw DiscordVoiceRTPError.truncatedCSRCList(
                expectedHeaderBytes: csrcEnd,
                actualPacketBytes: packet.count
            )
        }

        guard packet[0] & 0x10 != 0 else {
            return csrcEnd
        }

        let preambleEnd = csrcEnd + 4
        guard packet.count >= preambleEnd else {
            throw DiscordVoiceRTPError.truncatedExtensionPreamble
        }
        let wordCount = Int(readUInt16(packet, at: csrcEnd + 2))
        let extensionByteCount = wordCount * 4
        let extensionEnd = preambleEnd + extensionByteCount
        guard extensionEnd <= maximumPacketSize else {
            throw DiscordVoiceRTPError.packetTooLarge(maximum: maximumPacketSize, actual: extensionEnd)
        }
        guard packet.count >= extensionEnd else {
            throw DiscordVoiceRTPError.truncatedExtensionData(
                expectedHeaderBytes: extensionEnd,
                actualPacketBytes: packet.count
            )
        }
        return extensionEnd
    }

    public func decodeHeader(from packet: [UInt8]) throws -> DiscordVoiceRTPHeader {
        let headerLength = try unencryptedHeaderLength(in: packet)
        let first = packet[0]
        let csrcCount = Int(first & 0x0f)
        var csrcs: [UInt32] = []
        csrcs.reserveCapacity(csrcCount)
        var cursor = DiscordVoiceRTPHeader.baseLength
        for _ in 0..<csrcCount {
            csrcs.append(readUInt32(packet, at: cursor))
            cursor += 4
        }

        var parsedExtension: DiscordVoiceRTPHeaderExtension?
        if first & 0x10 != 0 {
            let profile = readUInt16(packet, at: cursor)
            let wordCount = Int(readUInt16(packet, at: cursor + 2))
            let dataStart = cursor + 4
            let dataEnd = dataStart + (wordCount * 4)
            parsedExtension = try DiscordVoiceRTPHeaderExtension(
                profile: profile,
                data: Array(packet[dataStart..<dataEnd])
            )
            cursor = dataEnd
        }

        precondition(cursor == headerLength)
        return try DiscordVoiceRTPHeader(
            marker: packet[1] & 0x80 != 0,
            hasPadding: first & 0x20 != 0,
            payloadType: packet[1] & 0x7f,
            sequence: readUInt16(packet, at: 2),
            timestamp: readUInt32(packet, at: 4),
            ssrc: readUInt32(packet, at: 8),
            csrcs: csrcs,
            headerExtension: parsedExtension
        )
    }

    /// Splits an RTPSIZE-style packet without reading the protected body.
    /// `trailingByteCount` can reserve an authenticated transport suffix such as
    /// a nonce counter while leaving its contents opaque to this RTP layer.
    public func protectedLayout(
        in packet: [UInt8],
        trailingByteCount: Int = 0
    ) throws -> DiscordVoiceRTPProtectedLayout {
        guard trailingByteCount >= 0 else {
            throw DiscordVoiceRTPError.invalidTrailingByteCount(trailingByteCount)
        }
        let headerLength = try unencryptedHeaderLength(in: packet)
        guard trailingByteCount <= packet.count - headerLength else {
            throw DiscordVoiceRTPError.trailingBytesConsumePayload
        }
        let trailingStart = packet.count - trailingByteCount
        return DiscordVoiceRTPProtectedLayout(
            headerRange: 0..<headerLength,
            protectedPayloadRange: headerLength..<trailingStart,
            trailingRange: trailingStart..<packet.count
        )
    }

    /// Splits a plaintext RTP packet and validates RFC 3550 payload padding.
    /// Call this only after any protected payload has been authenticated and
    /// decrypted; `protectedLayout` intentionally does not inspect these bytes.
    public func plaintextLayout(in packet: [UInt8]) throws -> DiscordVoiceRTPPlaintextLayout {
        let headerLength = try unencryptedHeaderLength(in: packet)
        let hasPadding = packet[0] & 0x20 != 0
        guard hasPadding else {
            return DiscordVoiceRTPPlaintextLayout(
                headerRange: 0..<headerLength,
                payloadRange: headerLength..<packet.count,
                paddingRange: packet.count..<packet.count
            )
        }
        guard packet.count > headerLength else {
            throw DiscordVoiceRTPError.missingPadding
        }
        let paddingCount = Int(packet[packet.count - 1])
        let availablePayloadBytes = packet.count - headerLength
        guard paddingCount > 0, paddingCount <= availablePayloadBytes else {
            throw DiscordVoiceRTPError.invalidPaddingCount(paddingCount)
        }
        let paddingStart = packet.count - paddingCount
        return DiscordVoiceRTPPlaintextLayout(
            headerRange: 0..<headerLength,
            payloadRange: headerLength..<paddingStart,
            paddingRange: paddingStart..<packet.count
        )
    }

    private func validatePacketBounds(_ packet: [UInt8]) throws {
        guard packet.count <= maximumPacketSize else {
            throw DiscordVoiceRTPError.packetTooLarge(maximum: maximumPacketSize, actual: packet.count)
        }
        guard packet.count >= DiscordVoiceRTPHeader.baseLength else {
            throw DiscordVoiceRTPError.packetTooShort(
                minimum: DiscordVoiceRTPHeader.baseLength,
                actual: packet.count
            )
        }
    }

    private func validateFixedHeader(_ packet: [UInt8]) throws {
        let version = packet[0] >> 6
        guard version == DiscordVoiceRTPHeader.version else {
            throw DiscordVoiceRTPError.unsupportedVersion(version)
        }
        let payloadType = packet[1] & 0x7f
        guard DiscordVoiceRTPHeader.acceptedPayloadTypes.contains(payloadType) else {
            throw DiscordVoiceRTPError.unexpectedPayloadType(payloadType)
        }
    }

    private func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private func readUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
    }

    private func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24)
            | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8)
            | UInt32(bytes[index + 3])
    }
}

public struct DiscordVoiceRTPClockTick: Equatable, Sendable {
    public let sequence: UInt16
    public let timestamp: UInt32
}

/// A single-owner, deterministic 48 kHz RTP frame clock.
///
/// Initial values are always injected by the caller. Production code may obtain
/// them from a secure random source, while tests can provide fixed values.
public struct DiscordVoiceRTPClock: Equatable, Sendable {
    public static let sampleRate: UInt32 = 48_000
    public static let defaultSamplesPerFrame: UInt32 = 960
    public static let maximumOpusSamplesPerFrame: UInt32 = 5_760

    public private(set) var sequence: UInt16
    public private(set) var timestamp: UInt32
    public let samplesPerFrame: UInt32

    public init(
        initialSequence: UInt16,
        initialTimestamp: UInt32,
        samplesPerFrame: UInt32 = Self.defaultSamplesPerFrame
    ) throws {
        guard (1...Self.maximumOpusSamplesPerFrame).contains(samplesPerFrame) else {
            throw DiscordVoiceRTPError.invalidSamplesPerFrame(samplesPerFrame)
        }
        self.sequence = initialSequence
        self.timestamp = initialTimestamp
        self.samplesPerFrame = samplesPerFrame
    }

    /// Returns the current RTP position, then advances with wrapping arithmetic.
    public mutating func next() -> DiscordVoiceRTPClockTick {
        let tick = DiscordVoiceRTPClockTick(sequence: sequence, timestamp: timestamp)
        sequence &+= 1
        timestamp &+= samplesPerFrame
        return tick
    }
}

/// A single-owner, deterministic 90 kHz RTP clock for video frames.
///
/// Video RTP uses the fixed 90,000 Hz media clock. Every packet of one frame
/// shares a timestamp and the timestamp advances by `ticksPerFrame` between
/// frames (90,000 / frame rate; the default 3,000 is 30 fps). A frame that
/// exceeds the path MTU occupies several packets, so `nextFrame(fragmentCount:)`
/// reserves one timestamp plus a contiguous run of sequence numbers for the
/// whole frame; `next()` remains the single-packet case. Initial values are
/// always injected by the caller — production from a secure random source,
/// tests from fixed values.
///
/// Boundary honesty: this is RTP bookkeeping only. No video capture, encoder,
/// receive, or render path exists in this repository.
public struct DiscordVoiceVideoRTPClock: Equatable, Sendable {
    public static let sampleRate: UInt32 = 90_000
    /// 30 fps at the 90 kHz video clock.
    public static let defaultTicksPerFrame: UInt32 = 3_000
    /// 1 fps floor: a frame may never advance more than one second.
    public static let maximumTicksPerFrame: UInt32 = 90_000

    public private(set) var sequence: UInt16
    public private(set) var timestamp: UInt32
    public let ticksPerFrame: UInt32

    public init(
        initialSequence: UInt16,
        initialTimestamp: UInt32,
        ticksPerFrame: UInt32 = Self.defaultTicksPerFrame
    ) throws {
        guard (1...Self.maximumTicksPerFrame).contains(ticksPerFrame) else {
            throw DiscordVoiceRTPError.invalidVideoTicksPerFrame(ticksPerFrame)
        }
        self.sequence = initialSequence
        self.timestamp = initialTimestamp
        self.ticksPerFrame = ticksPerFrame
    }

    /// Returns the current RTP position, then advances with wrapping arithmetic.
    public mutating func next() -> DiscordVoiceRTPClockTick {
        let tick = DiscordVoiceRTPClockTick(sequence: sequence, timestamp: timestamp)
        sequence &+= 1
        timestamp &+= ticksPerFrame
        return tick
    }

    /// Reserves the RTP position of one whole frame that will be sent as
    /// `fragmentCount` packets: the returned tick is the base sequence number
    /// and the single timestamp every fragment of the frame carries. The
    /// sequence advances by exactly `fragmentCount` (wrapping) so the next
    /// frame starts after this frame's last fragment, while the timestamp
    /// advances by one frame, not one packet.
    ///
    /// The bound is `UInt16.max` because the sequence space is 16 bits: a
    /// frame that claimed more positions than the space holds would alias its
    /// own fragments. Callers fail closed rather than truncate.
    public mutating func nextFrame(fragmentCount: Int) throws -> DiscordVoiceRTPClockTick {
        guard (1...Int(UInt16.max)).contains(fragmentCount) else {
            throw DiscordVoiceRTPError.invalidFragmentCount(fragmentCount)
        }
        let tick = DiscordVoiceRTPClockTick(sequence: sequence, timestamp: timestamp)
        sequence &+= UInt16(fragmentCount)
        timestamp &+= ticksPerFrame
        return tick
    }
}

public enum DiscordVoiceRTPMediaKind: String, Equatable, Hashable, Sendable {
    case audio
    case video
    case screen
}

public struct DiscordVoiceRTPSource: Equatable, Hashable, Sendable {
    public let ssrc: UInt32
    public let userID: String
    public let mediaKind: DiscordVoiceRTPMediaKind

    public init(ssrc: UInt32, userID: String, mediaKind: DiscordVoiceRTPMediaKind = .audio) {
        self.ssrc = ssrc
        self.userID = userID
        self.mediaKind = mediaKind
    }
}

/// A bounded mapping from RTP SSRC values to Discord media sources.
public struct DiscordVoiceRTPSourceMap: Equatable, Sendable {
    public let capacity: Int
    private var sourcesBySSRC: [UInt32: DiscordVoiceRTPSource]

    public init(capacity: Int = 256) throws {
        guard capacity > 0 else {
            throw DiscordVoiceRTPError.invalidMappingCapacity(capacity)
        }
        self.capacity = capacity
        self.sourcesBySSRC = [:]
        self.sourcesBySSRC.reserveCapacity(capacity)
    }

    public var count: Int { sourcesBySSRC.count }

    public subscript(ssrc ssrc: UInt32) -> DiscordVoiceRTPSource? {
        sourcesBySSRC[ssrc]
    }

    public mutating func upsert(_ source: DiscordVoiceRTPSource) throws {
        guard sourcesBySSRC[source.ssrc] != nil || sourcesBySSRC.count < capacity else {
            throw DiscordVoiceRTPError.mappingCapacityExceeded(capacity)
        }
        sourcesBySSRC[source.ssrc] = source
    }

    @discardableResult
    public mutating func remove(ssrc: UInt32) -> DiscordVoiceRTPSource? {
        sourcesBySSRC.removeValue(forKey: ssrc)
    }

    public func sources(for userID: String) -> [DiscordVoiceRTPSource] {
        sourcesBySSRC.values
            .filter { $0.userID == userID }
            .sorted { lhs, rhs in
                if lhs.mediaKind.rawValue == rhs.mediaKind.rawValue {
                    return lhs.ssrc < rhs.ssrc
                }
                return lhs.mediaKind.rawValue < rhs.mediaKind.rawValue
            }
    }
}

public enum DiscordVoiceRTPReplayDecision: Equatable, Sendable {
    case acceptedFirst
    case acceptedNewHighest(distance: UInt16)
    case acceptedReordered(distanceBehind: UInt16)
    case duplicate(distanceBehind: UInt16)
    case tooOld(distanceBehind: UInt16)
    case tooFarAhead(distance: UInt16)

    public var isAccepted: Bool {
        switch self {
        case .acceptedFirst, .acceptedNewHighest, .acceptedReordered:
            return true
        case .duplicate, .tooOld, .tooFarAhead:
            return false
        }
    }
}

/// A bounded replay/reorder window for RTP's wrapping 16-bit sequence space.
///
/// The window records at most 64 sequence numbers. Forward jumps larger than
/// `maximumForwardJump` are rejected without changing state. This is transport
/// bookkeeping only and does not provide authentication or encryption.
public struct DiscordVoiceRTPReplayWindow: Equatable, Sendable {
    public let windowSize: Int
    public let maximumForwardJump: UInt16
    public private(set) var highestSequence: UInt16?

    private var receivedBitmap: UInt64

    public init(windowSize: Int = 64, maximumForwardJump: UInt16 = 4_096) throws {
        guard (1...64).contains(windowSize) else {
            throw DiscordVoiceRTPError.invalidReplayWindowSize(windowSize)
        }
        guard maximumForwardJump > 0, maximumForwardJump < 0x8000 else {
            throw DiscordVoiceRTPError.invalidMaximumForwardJump(maximumForwardJump)
        }
        self.windowSize = windowSize
        self.maximumForwardJump = maximumForwardJump
        self.highestSequence = nil
        self.receivedBitmap = 0
    }

    public mutating func observe(_ sequence: UInt16) -> DiscordVoiceRTPReplayDecision {
        guard let highestSequence else {
            self.highestSequence = sequence
            receivedBitmap = 1
            return .acceptedFirst
        }

        let forwardDistance = sequence &- highestSequence
        if forwardDistance == 0 {
            return .duplicate(distanceBehind: 0)
        }

        // Distances in the lower half of the modular sequence space are ahead;
        // distances in the upper half are behind the current maximum.
        if forwardDistance < 0x8000 {
            guard forwardDistance <= maximumForwardJump else {
                return .tooFarAhead(distance: forwardDistance)
            }
            let shift = Int(forwardDistance)
            if shift >= windowSize {
                receivedBitmap = 1
            } else {
                receivedBitmap = (receivedBitmap << shift) | 1
                receivedBitmap &= activeWindowMask
            }
            self.highestSequence = sequence
            return .acceptedNewHighest(distance: forwardDistance)
        }

        let distanceBehind = highestSequence &- sequence
        guard Int(distanceBehind) < windowSize else {
            return .tooOld(distanceBehind: distanceBehind)
        }
        let bit = UInt64(1) << UInt64(distanceBehind)
        if receivedBitmap & bit != 0 {
            return .duplicate(distanceBehind: distanceBehind)
        }
        receivedBitmap |= bit
        return .acceptedReordered(distanceBehind: distanceBehind)
    }

    private var activeWindowMask: UInt64 {
        windowSize == 64 ? UInt64.max : (UInt64(1) << UInt64(windowSize)) - 1
    }
}
