import Foundation

// Voice Gateway v8 video *signaling models only*.
//
// This file models the JSON wire shapes for Opcode 12 Video and Opcode 15
// Media Sink Wants, plus SSRC allocation and participant-mapping state, as
// documented by the community Voice Gateway reference (docs.discord.food,
// "voice-connections", formerly userdoccers). No video capture, codec,
// RTP packetization, or DAVE video-frame encryption path exists in this
// repository; nothing here transmits or receives media. Video remains
// independently incomplete from voice audio.

/// Local parsing bounds for video signaling payloads. The numeric limits are
/// AbbeyBot's defensive parsing bounds, not documented protocol limits, except
/// where noted (quality 0-100 is documented).
enum VoiceGatewayV8VideoBounds {
    /// Documented media types are `video`, `screen`, and `test`; unknown
    /// bounded values are tolerated for forward compatibility.
    static let mediaType = 32
    static let rid = 32
    static let resolutionType = 32
    /// Documented range: "The media quality to send (0-100, default 0)".
    static let qualityRange = 0...100
    static let maximumStreams = 32
    static let maximumBitrate = 1_000_000_000
    static let maximumFramerate = 1_000
    static let maximumResolutionDimension = 32_768
    static let maximumSinkWantEntries = 1_024
    /// Matches the Clients Connect participant bound in VoiceGatewayV8Models.
    static let maximumParticipants = 10_000
}

/// Validation shared by Identify proposals, Ready allocations, and Opcode 12
/// announcements. Keeping the rules here prevents one wire path from accepting
/// an allocation that another path cannot safely publish or index.
enum VoiceGatewayV8VideoValidation {
    static func validateIdentifyStreams(_ streams: [VoiceGatewayV8Stream]) throws {
        guard !streams.isEmpty, streams.count <= VoiceGatewayV8VideoBounds.maximumStreams else {
            throw VoiceGatewayV8Error.malformedPayload
        }

        var rids = Set<String>()
        for stream in streams {
            guard stream.type != nil,
                  let rid = stream.rid,
                  rids.insert(rid).inserted,
                  stream.ssrc == nil,
                  stream.rtxSSRC == nil
            else { throw VoiceGatewayV8Error.malformedPayload }
        }
    }

    static func validateNegotiatedStreams(
        _ streams: [VoiceGatewayV8Stream],
        audioSSRC: UInt32,
        requireType: Bool,
        failure: VoiceGatewayV8Error
    ) throws {
        guard audioSSRC != 0,
              !streams.isEmpty,
              streams.count <= VoiceGatewayV8VideoBounds.maximumStreams
        else { throw failure }

        var rids = Set<String>()
        var claimedSSRCs: Set<UInt32> = [audioSSRC]
        for stream in streams {
            guard (!requireType || stream.type != nil),
                  let rid = stream.rid,
                  rids.insert(rid).inserted,
                  let primarySSRC = stream.ssrc,
                  primarySSRC != 0,
                  let rtxSSRC = stream.derivedRTXSSRC,
                  rtxSSRC != 0,
                  claimedSSRCs.insert(primarySSRC).inserted,
                  claimedSSRCs.insert(rtxSSRC).inserted
            else { throw failure }
        }
    }
}

/// `max_resolution` object of a stream: `type` is documented as `fixed` or
/// `source`; width/height are the fixed dimensions, or `0` for source.
public struct VoiceGatewayV8StreamResolution: Codable, Equatable, Sendable {
    public let type: String
    public let width: Int
    public let height: Int

    public init(type: String, width: Int, height: Int) throws {
        try VoiceGatewayV8Bounds.require(
            type,
            field: "max_resolution.type",
            maximum: VoiceGatewayV8VideoBounds.resolutionType
        )
        guard (0...VoiceGatewayV8VideoBounds.maximumResolutionDimension).contains(width),
              (0...VoiceGatewayV8VideoBounds.maximumResolutionDimension).contains(height)
        else { throw VoiceGatewayV8Error.malformedPayload }
        self.type = type
        self.width = width
        self.height = height
    }

    func validated() throws -> Self { try Self(type: type, width: width, height: height) }
}

/// One simulcast stream object, shared by Identify, Ready, and Video payloads.
///
/// The documented derivation: "If [`rtx_ssrc` is] omitted for a negotiated
/// video stream, clients should derive the RTX SSRC as the primary stream
/// `ssrc + 1`."
public struct VoiceGatewayV8Stream: Codable, Equatable, Sendable {
    /// The media type. The Stream Structure table documents `video`,
    /// `screen`, and `test`; server-sent Video stream objects omit the key
    /// (the negotiated underlying type is always `video`), so it is optional
    /// here. Clients should set it on streams they propose in Identify.
    public let type: String?
    public let rid: String?
    public let quality: Int?
    public let active: Bool?
    public let maxBitrate: Int?
    public let maxFramerate: Int?
    public let maxResolution: VoiceGatewayV8StreamResolution?
    public let ssrc: UInt32?
    public let rtxSSRC: UInt32?

    public init(
        type: String? = nil,
        rid: String? = nil,
        quality: Int? = nil,
        active: Bool? = nil,
        maxBitrate: Int? = nil,
        maxFramerate: Int? = nil,
        maxResolution: VoiceGatewayV8StreamResolution? = nil,
        ssrc: UInt32? = nil,
        rtxSSRC: UInt32? = nil
    ) throws {
        if let type {
            try VoiceGatewayV8Bounds.require(type, field: "type", maximum: VoiceGatewayV8VideoBounds.mediaType)
        }
        if let rid {
            try VoiceGatewayV8Bounds.require(rid, field: "rid", maximum: VoiceGatewayV8VideoBounds.rid)
        }
        if let quality, !VoiceGatewayV8VideoBounds.qualityRange.contains(quality) {
            throw VoiceGatewayV8Error.malformedPayload
        }
        if let maxBitrate, !(0...VoiceGatewayV8VideoBounds.maximumBitrate).contains(maxBitrate) {
            throw VoiceGatewayV8Error.malformedPayload
        }
        if let maxFramerate, !(0...VoiceGatewayV8VideoBounds.maximumFramerate).contains(maxFramerate) {
            throw VoiceGatewayV8Error.malformedPayload
        }
        self.type = type
        self.rid = rid
        self.quality = quality
        self.active = active
        self.maxBitrate = maxBitrate
        self.maxFramerate = maxFramerate
        self.maxResolution = try maxResolution?.validated()
        self.ssrc = ssrc
        self.rtxSSRC = rtxSSRC
    }

    /// The RTX SSRC to use for this stream: the explicit `rtx_ssrc` when
    /// present, otherwise the documented `ssrc + 1` derivation. Nil when the
    /// stream has no primary SSRC or the derivation would overflow.
    public var derivedRTXSSRC: UInt32? {
        if let rtxSSRC { return rtxSSRC }
        guard let ssrc, ssrc < UInt32.max else { return nil }
        return ssrc + 1
    }

    enum CodingKeys: String, CodingKey {
        case type, rid, quality, active, ssrc
        case maxBitrate = "max_bitrate"
        case maxFramerate = "max_framerate"
        case maxResolution = "max_resolution"
        case rtxSSRC = "rtx_ssrc"
    }

    func validated() throws -> Self {
        try Self(
            type: type,
            rid: rid,
            quality: quality,
            active: active,
            maxBitrate: maxBitrate,
            maxFramerate: maxFramerate,
            maxResolution: maxResolution,
            ssrc: ssrc,
            rtxSSRC: rtxSSRC
        )
    }
}

/// Opcode 12 Video: announces which assigned streams are currently active.
///
/// On send, `audio_ssrc` is this connection's audio SSRC from Ready,
/// `video_ssrc`/`rtx_ssrc` select the primary outbound video stream (both `0`
/// with an empty `streams` array when clearing video). On receive, the voice
/// server adds `user_id` and omits the top-level `rtx_ssrc` (received stream
/// objects can still include `rtx_ssrc`).
///
/// Documented requirement: at least one Video payload must be sent before
/// sending or receiving video data. This type is signaling-shape only — no
/// media path consumes it.
public struct VoiceGatewayV8Video: Codable, Equatable, Sendable {
    public static let opcode = 12

    public let audioSSRC: UInt32
    public let videoSSRC: UInt32
    /// Not sent by the voice server at the top level.
    public let rtxSSRC: UInt32?
    /// The authoritative list of primary and RTX SSRCs for every simulcast
    /// layer. Empty when clearing local video.
    public let streams: [VoiceGatewayV8Stream]
    /// Only sent by the voice server.
    public let userID: String?

    public init(
        audioSSRC: UInt32,
        videoSSRC: UInt32,
        rtxSSRC: UInt32? = nil,
        streams: [VoiceGatewayV8Stream],
        userID: String? = nil
    ) throws {
        guard streams.count <= VoiceGatewayV8VideoBounds.maximumStreams else {
            throw VoiceGatewayV8Error.malformedPayload
        }
        if let userID {
            try VoiceGatewayV8Bounds.require(userID, field: "user_id", maximum: VoiceGatewayV8Bounds.identifier)
        }
        let validatedStreams = try streams.map { try $0.validated() }
        if validatedStreams.isEmpty {
            guard audioSSRC != 0,
                  videoSSRC == 0,
                  rtxSSRC == nil || rtxSSRC == 0
            else { throw VoiceGatewayV8Error.malformedPayload }
        } else {
            try VoiceGatewayV8VideoValidation.validateNegotiatedStreams(
                validatedStreams,
                audioSSRC: audioSSRC,
                requireType: false,
                failure: .malformedPayload
            )
            guard videoSSRC != 0,
                  let selected = validatedStreams.first(where: { $0.ssrc == videoSSRC })
            else { throw VoiceGatewayV8Error.malformedPayload }
            if let rtxSSRC {
                guard rtxSSRC != 0, rtxSSRC == selected.derivedRTXSSRC else {
                    throw VoiceGatewayV8Error.malformedPayload
                }
            }
        }
        self.audioSSRC = audioSSRC
        self.videoSSRC = videoSSRC
        self.rtxSSRC = rtxSSRC
        self.streams = validatedStreams
        self.userID = userID
    }

    enum CodingKeys: String, CodingKey {
        case audioSSRC = "audio_ssrc"
        case videoSSRC = "video_ssrc"
        case rtxSSRC = "rtx_ssrc"
        case streams
        case userID = "user_id"
    }

    func validated() throws -> Self {
        try Self(audioSSRC: audioSSRC, videoSSRC: videoSSRC, rtxSSRC: rtxSSRC, streams: streams, userID: userID)
    }
}

/// Opcode 15 Media Sink Wants: desired media stream quality, keyed by primary
/// media SSRC (not RTX SSRC). The special `any` key applies to otherwise
/// unspecified streams. Values are 0-100 where 0 disables a stream. The
/// optional `pixelCounts` object gives approximate rendered pixel counts per
/// SSRC. Available on Gateway v5 and above; sent in both directions.
public struct VoiceGatewayV8MediaSinkWants: Codable, Equatable, Sendable {
    public static let opcode = 15

    /// Desired quality per primary media SSRC.
    public let wants: [UInt32: Int]
    /// Desired quality for all otherwise unspecified streams.
    public let anyQuality: Int?
    /// Approximate rendered pixel count per primary media SSRC.
    public let pixelCounts: [UInt32: Double]?

    public init(wants: [UInt32: Int], anyQuality: Int? = nil, pixelCounts: [UInt32: Double]? = nil) throws {
        guard wants.count <= VoiceGatewayV8VideoBounds.maximumSinkWantEntries else {
            throw VoiceGatewayV8Error.malformedPayload
        }
        for quality in wants.values where !VoiceGatewayV8VideoBounds.qualityRange.contains(quality) {
            throw VoiceGatewayV8Error.malformedPayload
        }
        if let anyQuality, !VoiceGatewayV8VideoBounds.qualityRange.contains(anyQuality) {
            throw VoiceGatewayV8Error.malformedPayload
        }
        if let pixelCounts {
            guard pixelCounts.count <= VoiceGatewayV8VideoBounds.maximumSinkWantEntries else {
                throw VoiceGatewayV8Error.malformedPayload
            }
            for count in pixelCounts.values where !count.isFinite || count < 0 {
                throw VoiceGatewayV8Error.malformedPayload
            }
        }
        self.wants = wants
        self.anyQuality = anyQuality
        self.pixelCounts = pixelCounts
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        guard container.allKeys.count <= VoiceGatewayV8VideoBounds.maximumSinkWantEntries + 2 else {
            throw VoiceGatewayV8Error.malformedPayload
        }
        var wants: [UInt32: Int] = [:]
        var anyQuality: Int?
        var pixelCounts: [UInt32: Double]?
        for key in container.allKeys {
            switch key.stringValue {
            case "any":
                anyQuality = try container.decode(Int.self, forKey: key)
            case "pixelCounts":
                let raw = try container.decode([String: Double].self, forKey: key)
                var mapped: [UInt32: Double] = [:]
                mapped.reserveCapacity(raw.count)
                for (rawSSRC, count) in raw {
                    guard let ssrc = UInt32(rawSSRC) else { throw VoiceGatewayV8Error.malformedPayload }
                    mapped[ssrc] = count
                }
                pixelCounts = mapped
            default:
                // Every other key must be a decimal primary media SSRC.
                guard let ssrc = UInt32(key.stringValue) else {
                    throw VoiceGatewayV8Error.malformedPayload
                }
                wants[ssrc] = try container.decode(Int.self, forKey: key)
            }
        }
        self = try Self(wants: wants, anyQuality: anyQuality, pixelCounts: pixelCounts)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (ssrc, quality) in wants {
            try container.encode(quality, forKey: DynamicKey(stringValue: String(ssrc)))
        }
        if let anyQuality {
            try container.encode(anyQuality, forKey: DynamicKey(stringValue: "any"))
        }
        if let pixelCounts {
            var nested = container.nestedContainer(keyedBy: DynamicKey.self, forKey: DynamicKey(stringValue: "pixelCounts"))
            for (ssrc, count) in pixelCounts {
                try nested.encode(count, forKey: DynamicKey(stringValue: String(ssrc)))
            }
        }
    }

    func validated() throws -> Self {
        try Self(wants: wants, anyQuality: anyQuality, pixelCounts: pixelCounts)
    }
}

/// Server-assigned local video SSRC allocation.
///
/// Video state is negotiated in three places: Identify advertises video
/// support and proposed simulcast RIDs, Ready assigns the actual primary and
/// RTX SSRCs for those streams, and Video announces which assigned streams
/// are currently active. This type captures step two and produces step-three
/// announcements. Clients never invent video SSRCs — they use the assignment
/// from Ready (deriving `rtx_ssrc` as `ssrc + 1` when omitted).
public struct VoiceGatewayV8VideoSSRCAllocation: Equatable, Sendable {
    public let audioSSRC: UInt32
    public let streams: [VoiceGatewayV8Stream]

    /// Builds an allocation from the Ready audio SSRC and the populated
    /// `streams` array. Every stream must carry a server-assigned primary
    /// SSRC and a usable (explicit or derivable) RTX SSRC.
    public init(audioSSRC: UInt32, streams: [VoiceGatewayV8Stream]) throws {
        let validatedStreams = try streams.map { try $0.validated() }
        try VoiceGatewayV8VideoValidation.validateNegotiatedStreams(
            validatedStreams,
            audioSSRC: audioSSRC,
            requireType: true,
            failure: .malformedPayload
        )
        self.audioSSRC = audioSSRC
        self.streams = validatedStreams
    }

    /// The Opcode 12 Video announcement activating the streams whose `rid`
    /// appears in `activeRIDs`. The top-level `video_ssrc`/`rtx_ssrc` pair
    /// points at the selected primary outbound stream — the highest-quality
    /// active layer.
    public func announcement(activeRIDs: Set<String>) throws -> VoiceGatewayV8Video {
        let announced = try streams.map { stream in
            try VoiceGatewayV8Stream(
                type: stream.type,
                rid: stream.rid,
                quality: stream.quality,
                active: stream.rid.map(activeRIDs.contains) ?? false,
                maxBitrate: stream.maxBitrate,
                maxFramerate: stream.maxFramerate,
                maxResolution: stream.maxResolution,
                ssrc: stream.ssrc,
                rtxSSRC: stream.derivedRTXSSRC
            )
        }
        let primary = announced
            .filter { $0.active == true }
            .max { ($0.quality ?? 0) < ($1.quality ?? 0) }
        guard let primary, let primarySSRC = primary.ssrc, let primaryRTX = primary.derivedRTXSSRC else {
            throw VoiceGatewayV8Error.malformedPayload
        }
        return try VoiceGatewayV8Video(
            audioSSRC: audioSSRC,
            videoSSRC: primarySSRC,
            rtxSSRC: primaryRTX,
            streams: announced
        )
    }

    /// The Opcode 12 Video announcement clearing local video: `video_ssrc`
    /// and `rtx_ssrc` of `0` with an empty `streams` array.
    public func clearingAnnouncement() throws -> VoiceGatewayV8Video {
        try VoiceGatewayV8Video(audioSSRC: audioSSRC, videoSSRC: 0, rtxSSRC: 0, streams: [])
    }
}

/// Receive-side participant mapping: user ID ↔ announced SSRCs.
///
/// Receivers must cache SSRC ownership from every received Video payload:
/// `audio_ssrc` maps the user's audio stream, each stream `ssrc` maps primary
/// video RTP, and each stream `rtx_ssrc` maps repaired video RTP for the same
/// stream. Video RTP packets are not self-describing enough to choose a user
/// without this state.
///
/// Resume-safety: on a successful buffered resume (Opcode 7 → Opcode 9) the
/// voice server replays missed messages, so this map stays valid and should
/// be retained. On a fresh Identify (new session) the server re-announces
/// each participant's video state via Opcode 12, so the map must be rebuilt
/// from scratch — call `removeAll()` before re-identifying.
public struct VoiceGatewayV8VideoParticipantMap: Equatable, Sendable {
    public struct Participant: Equatable, Sendable {
        public let audioSSRC: UInt32
        /// Zero when the user has cleared video.
        public let videoSSRC: UInt32
        public let streams: [VoiceGatewayV8Stream]
    }

    private var participants: [String: Participant] = [:]
    /// Reverse ownership is authoritative for deterministic O(1) resolution.
    /// It is always replaced transactionally with `participants`.
    private var ssrcOwners: [UInt32: String] = [:]

    public init() {}

    public var count: Int { participants.count }

    /// Applies a server-sent Opcode 12 Video payload. Throws when the payload
    /// has no `user_id` (a client-built announcement) or when the participant
    /// bound would be exceeded.
    public mutating func apply(_ video: VoiceGatewayV8Video) throws {
        let video = try video.validated()
        guard let userID = video.userID else { throw VoiceGatewayV8Error.malformedPayload }
        if participants[userID] == nil,
           participants.count >= VoiceGatewayV8VideoBounds.maximumParticipants
        {
            throw VoiceGatewayV8Error.malformedPayload
        }

        let replacement = Participant(
            audioSSRC: video.audioSSRC,
            videoSSRC: video.videoSSRC,
            streams: video.streams
        )
        let replacementSSRCs = Self.claimedSSRCs(for: replacement)
        for ssrc in replacementSSRCs {
            if let owner = ssrcOwners[ssrc], owner != userID {
                throw VoiceGatewayV8Error.malformedPayload
            }
        }

        // Build both indexes before publishing either one. A collision above
        // leaves the previous participant and all reverse ownership untouched.
        var nextParticipants = participants
        var nextOwners = ssrcOwners
        if let previous = participants[userID] {
            for ssrc in Self.claimedSSRCs(for: previous) where nextOwners[ssrc] == userID {
                nextOwners.removeValue(forKey: ssrc)
            }
        }
        nextParticipants[userID] = replacement
        for ssrc in replacementSSRCs {
            nextOwners[ssrc] = userID
        }
        participants = nextParticipants
        ssrcOwners = nextOwners
    }

    /// Discards a participant's SSRC state, per the documented Client
    /// Disconnect behavior ("the SSRC of the user should be discarded").
    public mutating func removeParticipant(userID: String) {
        guard let participant = participants[userID] else { return }
        var nextParticipants = participants
        var nextOwners = ssrcOwners
        nextParticipants.removeValue(forKey: userID)
        for ssrc in Self.claimedSSRCs(for: participant) where nextOwners[ssrc] == userID {
            nextOwners.removeValue(forKey: ssrc)
        }
        participants = nextParticipants
        ssrcOwners = nextOwners
    }

    /// Clears all state; required before re-identifying with a new session.
    public mutating func removeAll() {
        participants.removeAll()
        ssrcOwners.removeAll()
    }

    public func participant(userID: String) -> Participant? {
        participants[userID]
    }

    /// Resolves an RTP SSRC to the owning user, checking audio, primary
    /// video, per-stream primary, and per-stream RTX SSRCs.
    public func userID(forSSRC ssrc: UInt32) -> String? {
        ssrcOwners[ssrc]
    }

    private static func claimedSSRCs(for participant: Participant) -> Set<UInt32> {
        var claimed: Set<UInt32> = [participant.audioSSRC]
        if participant.videoSSRC != 0 {
            claimed.insert(participant.videoSSRC)
        }
        for stream in participant.streams {
            if let ssrc = stream.ssrc, ssrc != 0 {
                claimed.insert(ssrc)
            }
            if let rtxSSRC = stream.derivedRTXSSRC, rtxSSRC != 0 {
                claimed.insert(rtxSSRC)
            }
        }
        return claimed
    }
}
