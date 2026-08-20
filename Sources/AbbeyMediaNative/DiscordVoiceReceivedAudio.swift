import AbbeyCore
import Foundation

/// One authenticated, DAVE-unprotected, decoded 20 ms audio frame together
/// with the RTP identity of the source it came from.
///
/// Every field is read from the packet header **after** RTPSIZE
/// authentication succeeded, so `ssrc`, `sequence`, and `timestamp` describe
/// an authenticated packet — a portable jitter/mix layer can order and demux
/// on them without re-deriving anything from unauthenticated bytes.
public struct DiscordVoiceReceivedAudioFrame: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    /// Authenticated synchronization source of the sender.
    public let ssrc: UInt32
    /// Authenticated RTP sequence number, for reorder/duplicate policy.
    public let sequence: UInt16
    /// Authenticated RTP timestamp (48 kHz audio clock).
    public let timestamp: UInt32
    /// Interleaved stereo 48 kHz PCM for exactly this packet.
    public let pcm: [Int16]

    /// Diagnostics never carry PCM. Sample counts are shape, not content.
    public var description: String {
        "DiscordVoiceReceivedAudioFrame(ssrc: \(ssrc), sequence: \(sequence), "
            + "timestamp: \(timestamp), samples: \(pcm.count))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["receivedAudio": "<redacted>"], displayStyle: .struct)
    }
}
