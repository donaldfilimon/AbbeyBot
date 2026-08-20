import Testing
@testable import AbbeyCore

private enum CaptureLoopTestError: Error, Equatable {
    case startFailed
    case sendFailed
}

/// Deterministic capture source: the test owns the stream continuation and
/// pumps known PCM frames; `stopCapture()` records ordering and finishes the
/// stream like a real device teardown would.
private actor CaptureSourceDouble: DiscordVoiceCaptureSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var failNextStartFlag = false
    private var continuation: AsyncStream<[Int16]>.Continuation?
    private let recorder: CaptureOrderRecorder?

    init(recorder: CaptureOrderRecorder? = nil) {
        self.recorder = recorder
    }

    func failNextStart() {
        failNextStartFlag = true
    }

    func startCapture() async throws -> AsyncStream<[Int16]> {
        startCount += 1
        if failNextStartFlag {
            failNextStartFlag = false
            throw CaptureLoopTestError.startFailed
        }
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        return stream
    }

    func stopCapture() async {
        stopCount += 1
        await recorder?.record("sourceStopped")
        continuation?.finish()
        continuation = nil
    }

    func emit(_ pcm: [Int16]) {
        continuation?.yield(pcm)
    }

    /// Ends the stream without a stop — a device-loss stand-in.
    func finishStream() {
        continuation?.finish()
        continuation = nil
    }
}

private actor AudioFrameSenderDouble: DiscordVoiceAudioFrameSender {
    private(set) var frames: [[Int16]] = []
    private var failAtFrameIndex: Int?

    func failWhenFrameCountReaches(_ index: Int) {
        failAtFrameIndex = index
    }

    func sendAudioFrame(pcm: [Int16]) async throws {
        if let failAtFrameIndex, frames.count == failAtFrameIndex {
            throw CaptureLoopTestError.sendFailed
        }
        frames.append(pcm)
    }
}

private actor CaptureOrderRecorder {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor CaptureTerminalRecorder {
    private(set) var count = 0
    func fire() { count += 1 }
}

private func pcmFrame(seed: Int, count: Int = DiscordVoiceCaptureLoop.interleavedSampleCount) -> [Int16] {
    (0..<count).map { index in
        Int16(truncatingIfNeeded: index &* 31 &+ seed &* 733 &+ 1)
    }
}

private func waitUntil(
    _ condition: @escaping () async -> Bool
) async -> Bool {
    for _ in 0..<20_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

@Suite("Discord Voice capture loop")
struct DiscordVoiceCaptureLoopTests {
    @Test("capture frames reach the protected sender exactly and in order")
    func orderedFramesReachSender() async throws {
        let source = CaptureSourceDouble()
        let sender = AudioFrameSenderDouble()
        let loop = DiscordVoiceCaptureLoop(source: source, sender: sender)

        try await loop.start(generation: 1)
        let expected = [pcmFrame(seed: 0), pcmFrame(seed: 1), pcmFrame(seed: 2)]
        for frame in expected {
            await source.emit(frame)
        }

        #expect(await waitUntil { await sender.frames.count == 3 })
        #expect(await sender.frames == expected)
        let snapshot = await loop.snapshot()
        #expect(snapshot.phase == .capturing)
        #expect(snapshot.sentFrameCount == 3)

        let rendered = "\(loop) \(String(reflecting: loop)) \(snapshot)"
        #expect(!rendered.contains("733"))
        await loop.stop()
    }

    @Test("double start is rejected while running; stale and zero generations are rejected; equal generation restarts across a mute cycle")
    func generationAndRestartRules() async throws {
        let source = CaptureSourceDouble()
        let sender = AudioFrameSenderDouble()
        let loop = DiscordVoiceCaptureLoop(source: source, sender: sender)

        await #expect(throws: DiscordVoiceCaptureLoopError.staleGeneration) {
            try await loop.start(generation: 0)
        }

        try await loop.start(generation: 2)
        await #expect(throws: DiscordVoiceCaptureLoopError.alreadyRunning) {
            try await loop.start(generation: 2)
        }

        await loop.stop()
        #expect(await loop.snapshot().phase == .stopped)
        await #expect(throws: DiscordVoiceCaptureLoopError.staleGeneration) {
            try await loop.start(generation: 1)
        }

        // Mute/unmute cycle: the same established generation may restart.
        try await loop.start(generation: 2)
        #expect(await loop.snapshot().phase == .capturing)
        #expect(await source.startCount == 2)
        await loop.stop()
    }

    @Test("a sender failure fails closed: capture stops, nothing further is sent, terminal fires once")
    func sendFailureFailsClosed() async throws {
        let source = CaptureSourceDouble()
        let sender = AudioFrameSenderDouble()
        await sender.failWhenFrameCountReaches(1)
        let terminal = CaptureTerminalRecorder()
        let loop = DiscordVoiceCaptureLoop(source: source, sender: sender)
        await loop.setTerminalHandler { await terminal.fire() }

        try await loop.start(generation: 1)
        await source.emit(pcmFrame(seed: 0))
        await source.emit(pcmFrame(seed: 1))
        await source.emit(pcmFrame(seed: 2))

        #expect(await waitUntil { await source.stopCount >= 1 })
        #expect(await waitUntil { await terminal.count == 1 })
        #expect(await sender.frames == [pcmFrame(seed: 0)])
        #expect(await loop.snapshot().phase == .failed)

        // Late frames after the failure never reach the sender.
        await source.emit(pcmFrame(seed: 3))
        for _ in 0..<50 { await Task.yield() }
        #expect(await sender.frames.count == 1)
        #expect(await terminal.count == 1)
    }

    @Test("a malformed frame fails closed without sending anything")
    func malformedFrameFailsClosed() async throws {
        let source = CaptureSourceDouble()
        let sender = AudioFrameSenderDouble()
        let terminal = CaptureTerminalRecorder()
        let loop = DiscordVoiceCaptureLoop(source: source, sender: sender)
        await loop.setTerminalHandler { await terminal.fire() }

        try await loop.start(generation: 1)
        await source.emit(pcmFrame(seed: 0, count: 100))

        #expect(await waitUntil { await source.stopCount >= 1 })
        #expect(await waitUntil { await terminal.count == 1 })
        #expect(await sender.frames.isEmpty)
        #expect(await loop.snapshot().phase == .failed)
    }

    @Test("an unexpected capture end (device loss) fails closed and fires the terminal handler")
    func unexpectedStreamEndFailsClosed() async throws {
        let source = CaptureSourceDouble()
        let sender = AudioFrameSenderDouble()
        let terminal = CaptureTerminalRecorder()
        let loop = DiscordVoiceCaptureLoop(source: source, sender: sender)
        await loop.setTerminalHandler { await terminal.fire() }

        try await loop.start(generation: 1)
        await source.emit(pcmFrame(seed: 0))
        #expect(await waitUntil { await sender.frames.count == 1 })

        await source.finishStream()

        #expect(await waitUntil { await terminal.count == 1 })
        #expect(await loop.snapshot().phase == .failed)
        #expect(await source.stopCount >= 1)
    }

    @Test("stop() is ordered and final: the source stops before stop() returns and no late frame is sent; terminal never fires")
    func stopOrderedTeardown() async throws {
        let recorder = CaptureOrderRecorder()
        let source = CaptureSourceDouble(recorder: recorder)
        let sender = AudioFrameSenderDouble()
        let terminal = CaptureTerminalRecorder()
        let loop = DiscordVoiceCaptureLoop(source: source, sender: sender)
        await loop.setTerminalHandler { await terminal.fire() }

        try await loop.start(generation: 1)
        await source.emit(pcmFrame(seed: 0))
        #expect(await waitUntil { await sender.frames.count == 1 })

        await loop.stop()
        // Callers reset the media plane only after stop() returns; record the
        // reset marker here so the required ordering is asserted explicitly.
        await recorder.record("mediaReset")

        #expect(await recorder.snapshot() == ["sourceStopped", "mediaReset"])
        #expect(await loop.snapshot().phase == .stopped)

        await source.emit(pcmFrame(seed: 1))
        for _ in 0..<50 { await Task.yield() }
        #expect(await sender.frames.count == 1)
        #expect(await terminal.count == 0)
    }

    @Test("a capture source start failure fails closed and permits an explicit retry")
    func startFailureFailsClosedAndPermitsRetry() async throws {
        let source = CaptureSourceDouble()
        await source.failNextStart()
        let sender = AudioFrameSenderDouble()
        let loop = DiscordVoiceCaptureLoop(source: source, sender: sender)

        await #expect(throws: DiscordVoiceCaptureLoopError.captureUnavailable) {
            try await loop.start(generation: 1)
        }
        #expect(await loop.snapshot().phase == .failed)
        #expect(await sender.frames.isEmpty)

        // Operator grants permission and retries the same generation.
        try await loop.start(generation: 1)
        await source.emit(pcmFrame(seed: 0))
        #expect(await waitUntil { await sender.frames.count == 1 })
        await loop.stop()
    }
}
