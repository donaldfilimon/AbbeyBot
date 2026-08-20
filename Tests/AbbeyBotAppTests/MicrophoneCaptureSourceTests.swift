import AbbeyMediaMacOS
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
