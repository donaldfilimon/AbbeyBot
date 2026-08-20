import AbbeyCore
import AbbeyMediaMacOS

/// Bridges the portable `DiscordVoicePlaybackSink` contract to the hermetic
/// `AVAudioEngineAdapter` playback boundary, mirroring how
/// `MicrophoneCaptureSource` bridges capture.
///
/// The receive loop hands over already-mixed 20 ms frames; this type only
/// converts and enqueues. No PCM is retained, logged, or exposed, and a
/// playback failure propagates so the loop can fail closed rather than
/// continue pumping into a dead output.
struct SpeakerPlaybackSink: DiscordVoicePlaybackSink {
    private let adapter: AVAudioEngineAdapter

    init(adapter: AVAudioEngineAdapter) {
        self.adapter = adapter
    }

    func play(pcm: [Int16]) async throws {
        let frame = try AudioPCMFrame(int16: pcm)
        // `play` reports whether the frame was enqueued; a refusal is a real
        // failure for the loop, not something to swallow, because silently
        // dropping frames would look like a working call with no audio.
        guard try await adapter.play(frame) else {
            throw DiscordVoicePlaybackRejected.frameNotEnqueued
        }
    }
}

/// Redacted by construction: carries no PCM and no device detail.
enum DiscordVoicePlaybackRejected: Error, Equatable, Sendable, CustomStringConvertible {
    case frameNotEnqueued

    var description: String { "Playback refused a mixed audio frame" }
}
