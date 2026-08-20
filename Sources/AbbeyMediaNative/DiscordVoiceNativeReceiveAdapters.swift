import AbbeyCore
import Foundation

/// Bridges AbbeyCore's portable receive loop to the native media plane, which
/// owns the keys.
///
/// The loop routes by SSRC and applies jitter/PLC policy; the plane performs
/// AEAD open, DAVE unprotect, and Opus decode. Neither side needs the other's
/// concerns, and the loop never sees key material — the same split the send
/// path uses between `DiscordVoiceCaptureLoop` and `sendAudioFrame`.
///
/// The one thing this adapter adds is sender attribution. DAVE's `unprotect`
/// selects a per-participant ratchet, so it needs to know *who* sent a packet,
/// and only the Voice Gateway knows that — it learns SSRC ownership from
/// inbound Speaking (opcode 5). So the adapter reads the SSRC from the RTP
/// header and asks an injected resolver.
///
/// Reading that SSRC from an **unauthenticated** header is safe, and
/// deliberately so: a wrong or absent answer cannot leak audio. An unknown
/// SSRC is refused here, and a wrong one simply fails against that
/// participant's ratchet inside `unprotect`. Neither path yields PCM.
public struct DiscordVoiceNativeAudioFrameDecoder: DiscordVoiceAudioFrameDecoder {
    /// Resolves an SSRC to the user who owns it, or nil while unknown.
    public typealias SenderResolver = @Sendable (UInt32) async -> UInt64?

    private let plane: DiscordVoiceNativeMediaPlane
    private let resolveSender: SenderResolver

    public init(
        plane: DiscordVoiceNativeMediaPlane,
        resolveSender: @escaping SenderResolver
    ) {
        self.plane = plane
        self.resolveSender = resolveSender
    }

    public func decodeAudioFrame(packet: [UInt8]) async throws -> DiscordVoiceDecodedAudio {
        let codec = try DiscordVoiceRTPCodec()
        let header = try codec.decodeHeader(from: packet)
        guard let senderID = await resolveSender(header.ssrc) else {
            // Fail closed rather than guess an identity. Discord has simply
            // not told us who this SSRC belongs to yet; a Speaking frame will,
            // and the loop counts this as a drop in the meantime.
            throw DiscordVoiceNativeReceiveError.senderUnknown
        }
        let frame = try await plane.receiveAudioFrame(packet: packet, senderID: senderID)
        // The plane's SSRC is the authenticated one; prefer it over the header
        // value the loop used for routing.
        return DiscordVoiceDecodedAudio(ssrc: frame.ssrc, pcm: frame.pcm)
    }

    public func concealAudioFrame(ssrc: UInt32) async throws -> [Int16] {
        try await plane.concealAudioLoss(ssrc: ssrc)
    }
}

/// Redacted by construction: carries no SSRC, packet bytes, or identity.
public enum DiscordVoiceNativeReceiveError: Error, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// No user is known for the packet's SSRC yet, so DAVE cannot name a
    /// sender and the packet is refused rather than attributed by guess.
    case senderUnknown

    public var description: String {
        switch self {
        case .senderUnknown:
            "Native Discord media receive has no known sender for this source"
        }
    }

    public var debugDescription: String { description }
}
