import Foundation

// Video codec negotiation for Discord voice connections.
//
// The payload type an outbound video RTP packet carries must come from what
// the connection negotiated, never from whatever codec label a caller happens
// to hold. `DiscordVoiceVideoCodecNegotiation` models that as the
// intersection of two facts:
//
// 1. the *offer table* — the codecs this client proposes, each bound to the
//    dynamic RTP payload type this client would use for it, and
// 2. the *server's selection* — the codec name the voice server chose.
//
// `resolve(negotiatedCodecName:)` is the only route from a codec to a payload
// type. It fails closed when nothing was negotiated and when the negotiated
// codec is not in the offer table, so an unnegotiated or unmappable codec can
// never reach the RTP layer.
//
// WHERE THE SERVER'S SELECTION COMES FROM IS NOT MODELED IN THIS REPOSITORY.
// `VoiceGatewayV8Ready` carries `ssrc`, `ip`, `port`, `modes`, and `streams`
// (whose objects carry `type`, `rid`, `quality`, `active`, `max_bitrate`,
// `max_framerate`, `max_resolution`, `ssrc`, and `rtx_ssrc`) — no codec name
// and no payload type. `VoiceGatewayV8SessionDescription` carries `mode`,
// `secret_key`, and `dave_protocol_version` — likewise no codec. No codec
// field is decoded anywhere in this package. Adding one is a separate,
// deliberate wire-shape decision that must be verified against Discord rather
// than guessed at here. Until it exists, the only input `resolve` can be
// given is `nil`, which fails closed. That is the intended state: no video
// codec is negotiated, so no video may be sent.
//
// Boundary honesty: nothing in this file transmits, encodes, or decodes
// media, and no video path in this repository works.

/// Failures at the video codec negotiation boundary.
public enum DiscordVoiceVideoNegotiationError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyCodecOffer
    case duplicateCodecOffer(DiscordVoiceVideoCodec)
    case duplicateOfferedPayloadType(UInt8)
    case offeredPayloadTypeNotSupported(UInt8)
    case videoCodecNotNegotiated
    case unsupportedNegotiatedVideoCodec(String)

    public var description: String {
        switch self {
        case .emptyCodecOffer:
            return "Video codec offer table must contain at least one codec"
        case .duplicateCodecOffer(let codec):
            return "Video codec offer table repeats codec \(codec.rawValue)"
        case .duplicateOfferedPayloadType(let payloadType):
            return "Video codec offer table repeats payload type \(payloadType)"
        case .offeredPayloadTypeNotSupported(let payloadType):
            return "Payload type \(payloadType) is not a video payload type this RTP layer builds"
        case .videoCodecNotNegotiated:
            return "No video codec was negotiated for this connection"
        case .unsupportedNegotiatedVideoCodec(let name):
            // The name is remote input, so it is reported by length only; the
            // associated value carries it for callers that need to compare.
            return "Negotiated video codec (\(name.utf8.count) bytes) has no offered RTP mapping"
        }
    }
}

/// A video codec this client can name in a negotiation.
///
/// The raw values are the codec names Discord uses. H.265 is deliberately
/// absent: this repository models no payload type for it, so a negotiation
/// that selected it must fail closed rather than borrow another codec's.
public enum DiscordVoiceVideoCodec: String, CaseIterable, Equatable, Hashable, Sendable {
    case h264 = "H264"
    case vp8 = "VP8"
    case vp9 = "VP9"
    case av1 = "AV1"

    /// Matches a codec name from the wire, case-insensitively. Returns nil for
    /// any name this client does not model — including audio codecs.
    public init?(wireName: String) {
        let normalized = wireName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == normalized })
        else { return nil }
        self = match
    }
}

/// One codec this client proposes, bound to the RTP payload type it would send
/// for that codec.
public struct DiscordVoiceVideoCodecOffer: Equatable, Sendable {
    public let codec: DiscordVoiceVideoCodec
    public let payloadType: UInt8

    public init(codec: DiscordVoiceVideoCodec, payloadType: UInt8) throws {
        guard payloadType != DiscordVoiceRTPHeader.discordAudioPayloadType,
              DiscordVoiceRTPHeader.acceptedPayloadTypes.contains(payloadType)
        else {
            throw DiscordVoiceVideoNegotiationError.offeredPayloadTypeNotSupported(payloadType)
        }
        self.codec = codec
        self.payloadType = payloadType
    }

    /// Only for the compile-time default table below, whose payload types are
    /// the same constants `DiscordVoiceRTPHeader.acceptedPayloadTypes` is built
    /// from. `offerTableIsValidated` re-checks the table through the throwing
    /// initializer so this shortcut cannot hide an invalid constant.
    fileprivate init(uncheckedCodec: DiscordVoiceVideoCodec, payloadType: UInt8) {
        self.codec = uncheckedCodec
        self.payloadType = payloadType
    }
}

/// The outcome of a successful negotiation: which codec, and the payload type
/// the RTP header must carry for it.
public struct DiscordVoiceNegotiatedVideoCodec: Equatable, Sendable {
    public let codec: DiscordVoiceVideoCodec
    public let payloadType: UInt8
}

/// The codecs this client offers, and the only supported route from a
/// negotiated codec name to an RTP payload type. See the file header for why
/// no wire payload in this repository currently supplies that name.
public struct DiscordVoiceVideoCodecNegotiation: Equatable, Sendable {
    /// The codecs this client proposes, in Discord's documented dynamic
    /// payload-type assignment. These are an *offer*: being in this table does
    /// not make a codec usable, only nameable.
    public static let discordProposedOffers: [DiscordVoiceVideoCodecOffer] = [
        DiscordVoiceVideoCodecOffer(
            uncheckedCodec: .h264,
            payloadType: DiscordVoiceRTPHeader.discordVideoH264PayloadType
        ),
        DiscordVoiceVideoCodecOffer(
            uncheckedCodec: .vp8,
            payloadType: DiscordVoiceRTPHeader.discordVideoVP8PayloadType
        ),
        DiscordVoiceVideoCodecOffer(
            uncheckedCodec: .vp9,
            payloadType: DiscordVoiceRTPHeader.discordVideoVP9PayloadType
        ),
        DiscordVoiceVideoCodecOffer(
            uncheckedCodec: .av1,
            payloadType: DiscordVoiceRTPHeader.discordVideoAV1PayloadType
        ),
    ]

    public static let discordProposed = Self(uncheckedOffers: Self.discordProposedOffers)

    public let offers: [DiscordVoiceVideoCodecOffer]

    public init(offers: [DiscordVoiceVideoCodecOffer]) throws {
        guard !offers.isEmpty else {
            throw DiscordVoiceVideoNegotiationError.emptyCodecOffer
        }
        var seenCodecs = Set<DiscordVoiceVideoCodec>()
        var seenPayloadTypes = Set<UInt8>()
        for offer in offers {
            guard seenCodecs.insert(offer.codec).inserted else {
                throw DiscordVoiceVideoNegotiationError.duplicateCodecOffer(offer.codec)
            }
            guard seenPayloadTypes.insert(offer.payloadType).inserted else {
                throw DiscordVoiceVideoNegotiationError
                    .duplicateOfferedPayloadType(offer.payloadType)
            }
        }
        self.offers = offers
    }

    private init(uncheckedOffers: [DiscordVoiceVideoCodecOffer]) {
        self.offers = uncheckedOffers
    }

    /// Resolves the codec the voice server negotiated to the payload type this
    /// client offered for it.
    ///
    /// Fails closed, never guessing a codec, when: no codec was negotiated
    /// (`nil` or blank), the negotiated name is not a video codec this client
    /// models (H.265, an audio codec, an unknown name), or the codec is not in
    /// this connection's offer table.
    public func resolve(negotiatedCodecName: String?) throws -> DiscordVoiceNegotiatedVideoCodec {
        guard let negotiatedCodecName else {
            throw DiscordVoiceVideoNegotiationError.videoCodecNotNegotiated
        }
        let trimmed = negotiatedCodecName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DiscordVoiceVideoNegotiationError.videoCodecNotNegotiated
        }
        guard let codec = DiscordVoiceVideoCodec(wireName: trimmed),
              let offer = offers.first(where: { $0.codec == codec })
        else {
            throw DiscordVoiceVideoNegotiationError.unsupportedNegotiatedVideoCodec(trimmed)
        }
        return DiscordVoiceNegotiatedVideoCodec(
            codec: offer.codec,
            payloadType: offer.payloadType
        )
    }
}
