import AbbeyCore
import AbbeyMediaMacOS

/// Bridges the hermetic `AVAudioEngineAdapter` capture boundary to the
/// portable `DiscordVoiceCaptureSource` contract used by
/// `DiscordVoiceCaptureLoop`.
///
/// - Frames are the adapter's exact 20 ms, 48 kHz stereo interleaved frames,
///   converted to `Int16` here; no PCM is retained, logged, or exposed.
/// - Permission stays fail-closed: `startCapture()` defers to the adapter,
///   whose own preflight throws without an authorized microphone grant and
///   never prompts.
/// - Device loss stays fail-closed: any engine interruption or device/
///   configuration change finishes the delivered stream, which makes the
///   capture loop stop and report failure instead of continuing on a changed
///   device. There is no automatic restart.
actor MicrophoneCaptureSource: DiscordVoiceCaptureSource {
    private let adapter: AVAudioEngineAdapter
    private var activeContinuation: AsyncStream<[Int16]>.Continuation?
    private var forwardTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    init(adapter: AVAudioEngineAdapter) {
        self.adapter = adapter
    }

    deinit {
        forwardTask?.cancel()
        eventTask?.cancel()
        activeContinuation?.finish()
    }

    func startCapture() async throws -> AsyncStream<[Int16]> {
        guard activeContinuation == nil else {
            throw MediaRuntimeError.runtimeFailure("Microphone capture is already running")
        }
        // The bridge tasks drain the adapter's shared frame stream even while
        // no session is active, so frames buffered across a stop/start cycle
        // are discarded rather than delivered into a newer session.
        ensureBridgeTasks()
        _ = try await adapter.startCapture()
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        activeContinuation = continuation
        return stream
    }

    func stopCapture() async {
        let continuation = activeContinuation
        activeContinuation = nil
        continuation?.finish()
        await adapter.stopCapture()
    }

    private func ensureBridgeTasks() {
        if forwardTask == nil {
            let adapter = adapter
            forwardTask = Task { [weak self] in
                for await frame in adapter.capturedFrames {
                    guard let self else { return }
                    await self.deliver(frame.int16Samples)
                }
            }
        }
        if eventTask == nil {
            let adapter = adapter
            eventTask = Task { [weak self] in
                for await event in adapter.runtimeEvents {
                    guard let self else { return }
                    await self.handleRuntimeEvent(event)
                }
            }
        }
    }

    private func deliver(_ pcm: [Int16]) {
        _ = activeContinuation?.yield(pcm)
    }

    private func handleRuntimeEvent(_ event: AudioRuntimeEvent) {
        switch event {
        case .interruptionBegan, .configurationChanged, .deviceConfigurationChanged:
            // Fail closed: the engine stopped or its device changed underneath
            // the session. Finishing the stream terminates the capture loop
            // rather than letting capture continue on a changed device.
            let continuation = activeContinuation
            activeContinuation = nil
            continuation?.finish()
        case .interruptionEnded:
            // The adapter never auto-restarts after an interruption; a new
            // capture requires the operator to enable the microphone again.
            break
        }
    }
}
