import AbbeyCore
import AbbeyMediaMacOS
import Foundation
import Testing
@testable import AbbeyBotApp

private struct FixedMediaPolicy: MediaRuntimePolicyProviding {
    let disabled: Bool
    func mediaDisabled() -> Bool { disabled }
}

private struct FixedPermissionProvider: MediaPermissionProviding {
    let status: MediaAuthorizationStatus

    func authorizationStatus(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus {
        status
    }

    func requestAuthorization(for kind: MediaPermissionKind) async -> MediaAuthorizationStatus {
        status
    }
}

private actor CaptureRuntimeSpy: AudioEngineRuntime {
    private var deliver: (@Sendable (UInt64, AudioCaptureRuntimeDelivery) async -> Void)?
    private var eventHandler: (@Sendable (AudioRuntimeEvent) async -> Void)?
    private var lastGeneration: UInt64 = 0
    private(set) var captureStops = 0

    func installEventHandler(
        _ handler: @escaping @Sendable (AudioRuntimeEvent) async -> Void
    ) {
        eventHandler = handler
    }

    func startCapture(
        generation: UInt64,
        selection: AudioDeviceSelection,
        deliver: @escaping @Sendable (UInt64, AudioCaptureRuntimeDelivery) async -> Void
    ) async throws {
        lastGeneration = generation
        self.deliver = deliver
    }

    func schedulePlayback(
        _ frame: AudioPCMFrame,
        selection: AudioDeviceSelection,
        token: UInt64,
        completion: @escaping @Sendable (UInt64) async -> Void
    ) async throws {}

    func stopCapture() { captureStops += 1 }
    func stopPlayback() {}
    func stopNow() {}

    func emitSamples(_ samples: [Float]) async {
        await deliver?(lastGeneration, .samples(samples))
    }

    func emitEvent(_ event: AudioRuntimeEvent) async {
        await eventHandler?(event)
    }
}

/// Hermetic video boundary so the kill-switch tests can drive the real
/// `MacOSMediaSessionPlatform` without touching a camera or the screen.
private struct EmptyVideoSourceProvider: VideoCaptureSourceProviding {
    func sourceSnapshots(
        includeCameras: Bool,
        includeScreens: Bool
    ) async throws -> [VideoCaptureSourceSnapshot] { [] }
}

private actor InertVideoRuntime: VideoCaptureRuntime {
    func installEventHandler(
        _ handler: @escaping @Sendable (UInt64, VideoCaptureRuntimeEvent) async -> Void
    ) {}

    func startCapture(
        generation: UInt64,
        source: VideoCaptureSourceSnapshot,
        deliver: @escaping @Sendable (UInt64, VideoCaptureRuntimeDelivery) async -> Void
    ) async throws {}

    func stopCapture() {}
    func stopNow() {}
}

private actor RecordingFrameSender: DiscordVoiceAudioFrameSender {
    private(set) var sentFrames = 0

    func sendAudioFrame(pcm: [Int16]) async {
        sentFrames += 1
    }
}

/// One-shot cross-task signal: the capture loop's terminal handler and the
/// stream drain both complete on their own tasks.
private actor AsyncFlag {
    private var raised = false

    func raise() { raised = true }
    func isRaised() -> Bool { raised }
}

/// Bounded poll, so a regression fails the test instead of hanging the suite
/// on a stream that never finishes.
private func waitUntil(
    seconds: Double = 2,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

private struct MicrophoneFixture {
    let runtime: CaptureRuntimeSpy
    let adapter: AVAudioEngineAdapter
    let source: MicrophoneCaptureSource

    init() {
        runtime = CaptureRuntimeSpy()
        let policy = FixedMediaPolicy(disabled: false)
        adapter = AVAudioEngineAdapter(
            runtime: runtime,
            permissions: MediaPermissionController(
                provider: FixedPermissionProvider(status: .authorized),
                policy: policy
            ),
            policy: policy
        )
        source = MicrophoneCaptureSource(adapter: adapter)
    }

    /// The real platform wired to this fixture's shared adapter and bridge —
    /// the same sharing the desktop `MediaSessionModel` performs — with an
    /// inert video boundary and no permission prompts.
    func makePlatform() -> MacOSMediaSessionPlatform {
        let policy = FixedMediaPolicy(disabled: false)
        let permissions = MediaPermissionController(
            provider: FixedPermissionProvider(status: .authorized),
            policy: policy
        )
        return MacOSMediaSessionPlatform(
            permissions: permissions,
            audioCatalog: AudioDeviceCatalog(),
            audio: adapter,
            video: VideoCaptureAdapter(
                sourceProvider: EmptyVideoSourceProvider(),
                runtime: InertVideoRuntime(),
                permissions: permissions,
                policy: policy
            ),
            microphone: source
        )
    }
}

@Suite("Microphone capture source bridge")
struct MicrophoneCaptureSourceTests {
    @Test("forwards the adapter's exact 20 ms frames as interleaved Int16 PCM")
    func forwardsExactFrames() async throws {
        let fixture = MicrophoneFixture()
        let stream = try await fixture.source.startCapture()
        var iterator = stream.makeAsyncIterator()

        await fixture.runtime.emitSamples(
            Array(repeating: Float(0.5), count: AudioPCMFrame.interleavedSampleCount)
        )

        let frame = await iterator.next()
        #expect(frame?.count == AudioPCMFrame.interleavedSampleCount)
        #expect(frame?.allSatisfy { $0 == Int16((0.5 * Float(Int16.max)).rounded()) } == true)
        await fixture.source.stopCapture()
    }

    @Test("a runtime interruption or device change finishes the stream fail-closed")
    func runtimeEventFinishesStream() async throws {
        let fixture = MicrophoneFixture()
        let stream = try await fixture.source.startCapture()
        var iterator = stream.makeAsyncIterator()

        await fixture.runtime.emitEvent(.deviceConfigurationChanged)

        #expect(await iterator.next() == nil)
    }

    @Test("stopCapture finishes the stream and stops the adapter")
    func stopFinishesStreamAndStopsAdapter() async throws {
        let fixture = MicrophoneFixture()
        let stream = try await fixture.source.startCapture()
        var iterator = stream.makeAsyncIterator()

        await fixture.source.stopCapture()

        #expect(await iterator.next() == nil)
        #expect(await fixture.runtime.captureStops >= 1)
    }

    @Test("the platform kill switch finishes the delivered capture stream")
    func killSwitchFinishesStream() async throws {
        let fixture = MicrophoneFixture()
        let platform = fixture.makePlatform()
        let stream = try await fixture.source.startCapture()

        let drained = AsyncFlag()
        let drainTask = Task {
            for await _ in stream {}
            await drained.raise()
        }
        defer { drainTask.cancel() }

        await platform.stopAllCapture()

        #expect(await waitUntil { await drained.isRaised() })
    }

    @Test("the platform kill switch fails the capture loop closed")
    func killSwitchFailsCaptureLoopClosed() async throws {
        let fixture = MicrophoneFixture()
        let platform = fixture.makePlatform()
        let sender = RecordingFrameSender()
        let loop = DiscordVoiceCaptureLoop(source: fixture.source, sender: sender)
        let terminal = AsyncFlag()
        await loop.setTerminalHandler { await terminal.raise() }

        try await loop.start(generation: 1)
        let started = await loop.snapshot()
        #expect(started.phase == .capturing)

        await platform.stopAllCapture()

        // The loop's terminal path is what drops the controller's microphone
        // to disabled, so an unfinished stream leaves the UI reporting a live
        // microphone on a stopped device.
        #expect(await waitUntil { await terminal.isRaised() })
        let terminated = await loop.snapshot()
        #expect(terminated.phase == .failed)
    }

    @Test("capture can be enabled again after the kill switch fires")
    func captureRestartsAfterKillSwitch() async throws {
        let fixture = MicrophoneFixture()
        let platform = fixture.makePlatform()
        let sender = RecordingFrameSender()
        let loop = DiscordVoiceCaptureLoop(source: fixture.source, sender: sender)
        let terminal = AsyncFlag()
        await loop.setTerminalHandler { await terminal.raise() }

        try await loop.start(generation: 1)
        await platform.stopAllCapture()
        #expect(await waitUntil { await terminal.isRaised() })

        // A later enable attempt must reach the device again rather than
        // silently no-op until the whole session is torn down.
        try await loop.start(generation: 1)
        let restarted = await loop.snapshot()
        let adapterState = await fixture.adapter.currentState()
        #expect(restarted.phase == .capturing)
        #expect(adapterState == .capturing)

        await fixture.runtime.emitSamples(
            Array(repeating: Float(0.25), count: AudioPCMFrame.interleavedSampleCount)
        )
        #expect(await waitUntil { await sender.sentFrames >= 1 })

        await loop.stop()
    }

    @Test("a second start while a session is active fails closed")
    func doubleStartFailsClosed() async throws {
        let fixture = MicrophoneFixture()
        _ = try await fixture.source.startCapture()

        await #expect(throws: MediaRuntimeError.self) {
            _ = try await fixture.source.startCapture()
        }
        await fixture.source.stopCapture()
    }
}
