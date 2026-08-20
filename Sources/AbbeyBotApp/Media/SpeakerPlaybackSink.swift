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
        // `play` distinguishes two different things, and conflating them is a
        // bug I shipped in the first version of this file:
        //
        //   * returning `false` is EXPECTED BACKPRESSURE — the adapter is
        //     deafened, or its playback queue is full (which it already counts
        //     as a drop in `playbackDropCount`). The right response is to drop
        //     this 20 ms frame and keep going.
        //   * THROWING is a real refusal (e.g. media disabled by environment)
        //     and propagates, because the receive loop treats a playback
        //     failure as terminal.
        //
        // The first version turned `false` into a thrown error, so being
        // deafened — or one transient queue-full — would have killed receive
        // for the whole generation instead of dropping a single frame.
        _ = try await adapter.play(frame)
    }
}
