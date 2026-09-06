import AVFoundation
import Testing
@testable import AbbeyMediaMacOS

@Suite("AVAudioEngine adapter")
struct AVAudioEngineAdapterTests {
    @Test("capture assembles exact 20 ms frames across arbitrary buffer splits")
    func exactFramingAcrossSplits() async throws {
        let fixture = try AudioFixture()
        let adapter = fixture.adapter
        let stream = adapter.capturedFrames
        var iterator = stream.makeAsyncIterator()
        let generation = try await adapter.startCapture()

        await fixture.runtime.emit(Array(repeating: 1, count: 17), generation: generation)
        await fixture.runtime.emit(Array(repeating: 2, count: 1_000), generation: generation)
        await fixture.runtime.emit(Array(repeating: 3, count: 903), generation: generation)

        let frame = await iterator.next()
        #expect(frame?.frameCount == 960)
        #expect(frame?.float32Samples.count == 1_920)
        #expect(frame?.float32Samples.prefix(17).allSatisfy { $0 == 1 } == true)
        #expect(frame?.float32Samples.suffix(903).allSatisfy { $0 == 3 } == true)
    }

    @Test("bounded capture stream drops oldest frames and accounts for pressure")
    func captureOverflowIsBounded() async throws {
        let fixture = try AudioFixture(maximumCapturedFrames: 2)
        let adapter = fixture.adapter
        let generation = try await adapter.startCapture()
        for value in [Float(1), 2, 3] {
            await fixture.runtime.emit(
                Array(repeating: value, count: AudioPCMFrame.interleavedSampleCount),
                generation: generation
            )
        }

        #expect(await adapter.droppedCaptureFrameCount() == 1)
        var iterator = adapter.capturedFrames.makeAsyncIterator()
        #expect(await iterator.next()?.float32Samples.first == 2)
        #expect(await iterator.next()?.float32Samples.first == 3)
    }

    @Test("start and stop are idempotent and stale callbacks stay stopped")
    func startStopIdempotence() async throws {
        let fixture = try AudioFixture()
        let first = try await fixture.adapter.startCapture()
        let second = try await fixture.adapter.startCapture()
        #expect(first == second)
        #expect(await fixture.runtime.startCount() == 1)

        await fixture.adapter.stopCapture()
        await fixture.adapter.stopCapture()
        #expect(await fixture.runtime.captureStopCount() == 1)
        #expect(await fixture.adapter.currentState() == .stopped)

        await fixture.runtime.emit(
            Array(repeating: 1, count: AudioPCMFrame.interleavedSampleCount),
            generation: first
        )
        await fixture.runtime.emitDroppedSourceBuffers(3, generation: first)
        #expect(await fixture.adapter.droppedCaptureFrameCount() == 0)
        #expect(await fixture.adapter.droppedCaptureSourceBufferCount() == 0)
        #expect(await fixture.runtime.startCount() == 1)
    }

    @Test("concurrent capture starts share one in-flight runtime operation")
    func concurrentStartsAreSerialized() async throws {
        let fixture = try AudioFixture()
        await fixture.runtime.holdNextStart()

        let first = Task { try await fixture.adapter.startCapture() }
        await fixture.runtime.waitForStartCount(1)
        let second = Task { try await fixture.adapter.startCapture() }
        for _ in 0..<20 { await Task.yield() }

        #expect(await fixture.runtime.startCount() == 1)
        await fixture.runtime.releaseHeldStart()
        let firstGeneration = try await first.value
        let secondGeneration = try await second.value
        #expect(firstGeneration == secondGeneration)
        #expect(await fixture.runtime.startCount() == 1)
        #expect(await fixture.adapter.currentState() == .capturing)
    }

    @Test("capture startup failure rolls back runtime resources and permits retry")
    func failedStartCleansUpAndRetries() async throws {
        let fixture = try AudioFixture()
        await fixture.runtime.failNextStart()

        await #expect(throws: AudioRuntimeSpyError.startFailed) {
            try await fixture.adapter.startCapture()
        }
        #expect(await fixture.runtime.captureStopCount() == 1)
        guard case .failed = await fixture.adapter.currentState() else {
            Issue.record("Expected failed state after runtime startup error")
            return
        }

        let generation = try await fixture.adapter.startCapture()
        #expect(generation > 0)
        #expect(await fixture.runtime.startCount() == 2)
        #expect(await fixture.adapter.currentState() == .capturing)
    }

    @Test("source-buffer ingress is bounded and cannot deliver after finish")
    func sourceIngressBoundsAndFinish() async throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioPCMFrame.sampleRate,
                channels: AVAudioChannelCount(AudioPCMFrame.channelCount),
                interleaved: false
            )
        )
        let ingress = try #require(
            BoundedAudioCaptureIngress(format: format, frameCapacity: 960, capacity: 2)
        )
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        source.frameLength = 960

        ingress.enqueue(copying: source)
        ingress.enqueue(copying: source)
        ingress.enqueue(copying: source)

        #expect(ingress.pendingBufferCount == 2)
        #expect(ingress.takeDroppedCount() == 1)

        var iterator = ingress.slots.makeAsyncIterator()
        let first = try #require(await iterator.next())
        let second = try #require(await iterator.next())
        ingress.release(slot: first)
        ingress.release(slot: second)

        ingress.finish()
        ingress.enqueue(copying: source)
        #expect(await iterator.next() == nil)
        #expect(ingress.pendingBufferCount == 0)
    }

    @Test("configuration changes stop media and never auto restart")
    func noAutomaticRestart() async throws {
        let fixture = try AudioFixture()
        _ = try await fixture.adapter.startCapture()
        await fixture.runtime.emit(event: .configurationChanged)

        #expect(await fixture.adapter.currentState() == .configurationChanged)
        #expect(await fixture.runtime.stopNowCount() == 1)
        #expect(await fixture.runtime.startCount() == 1)

        await fixture.runtime.emit(event: .interruptionEnded)
        #expect(await fixture.runtime.startCount() == 1)
        #expect(await fixture.adapter.currentState() == .configurationChanged)
    }

    @Test("disabled mode blocks permission access and all engine starts")
    func disabledFailsClosed() async throws {
        let policy = FixedMediaPolicy(disabled: true)
        let permission = PermissionProviderSpy(status: .authorized)
        let runtime = AudioEngineRuntimeSpy()
        let adapter = AVAudioEngineAdapter(
            runtime: runtime,
            permissions: MediaPermissionController(provider: permission, policy: policy),
            policy: policy
        )

        await #expect(throws: MediaRuntimeError.disabledByEnvironment) {
            try await adapter.requestMicrophoneAuthorization()
        }
        await #expect(throws: MediaRuntimeError.disabledByEnvironment) {
            try await adapter.startCapture()
        }
        let frame = try AudioPCMFrame(
            float32: Array(repeating: 0, count: AudioPCMFrame.interleavedSampleCount)
        )
        await #expect(throws: MediaRuntimeError.disabledByEnvironment) {
            try await adapter.play(frame)
        }
        #expect(await permission.statusCalls() == 0)
        #expect(await permission.requestCalls() == 0)
        #expect(await runtime.startCount() == 0)
        #expect(await runtime.playCount() == 0)
    }

    @Test("permission denial blocks capture before the runtime")
    func permissionDenial() async throws {
        let permission = PermissionProviderSpy(status: .denied)
        let runtime = AudioEngineRuntimeSpy()
        let policy = FixedMediaPolicy(disabled: false)
        let adapter = AVAudioEngineAdapter(
            runtime: runtime,
            permissions: MediaPermissionController(provider: permission, policy: policy),
            policy: policy
        )

        await #expect(throws: MediaRuntimeError.microphonePermissionRequired(.denied)) {
            try await adapter.startCapture()
        }
        #expect(await permission.statusCalls() == 1)
        #expect(await permission.requestCalls() == 0)
        #expect(await runtime.startCount() == 0)
    }

    @Test("event installation cannot admit playback across a stop or deafen", arguments: [0, 1, 2])
    func playbackAdmissionInvalidatedDuringEventInstall(stopKind: Int) async throws {
        let fixture = try AudioFixture()
        let gate = PlaybackTestGate()
        await fixture.runtime.holdEventInstallation(gate)
        let frame = try AudioPCMFrame(
            float32: Array(repeating: 0, count: AudioPCMFrame.interleavedSampleCount)
        )
        let play = Task { try await fixture.adapter.play(frame) }
        await gate.waitUntilEntered()
        switch stopKind {
        case 0: await fixture.adapter.stopPlayback()
        case 1: await fixture.adapter.stopNow()
        default:
            await fixture.adapter.setDeafened(true)
            await fixture.adapter.setDeafened(false)
        }
        await gate.release()
        #expect(try await play.value == false)
        #expect(await fixture.runtime.playCount() == 0)
        #expect(await fixture.adapter.playbackQueueDepth() == 0)
        #expect(await fixture.adapter.currentState() == .stopped)
        #expect(try await fixture.adapter.play(frame))
    }

    @Test("event installation revalidates capacity after another caller fills the queue")
    func playbackAdmissionRechecksCapacity() async throws {
        let fixture = try AudioFixture(maximumPendingPlaybackFrames: 1)
        let gate = PlaybackTestGate()
        await fixture.runtime.holdEventInstallation(gate)
        let frame = try AudioPCMFrame(
            float32: Array(repeating: 0, count: AudioPCMFrame.interleavedSampleCount)
        )
        let first = Task { try await fixture.adapter.play(frame) }
        await gate.waitUntilEntered()
        #expect(try await fixture.adapter.play(frame))
        await gate.release()
        #expect(try await first.value == false)
        #expect(await fixture.adapter.playbackQueueDepth() == 1)
        #expect(await fixture.adapter.droppedPlaybackFrameCount() == 1)
        #expect(await fixture.runtime.playCount() == 1)
    }

    @Test("stop drains a cancellation-ignoring schedule before stopping runtime", arguments: [0, 1, 2, 3])
    func stopDuringPlaybackSchedule(stopKind: Int) async throws {
        let fixture = try AudioFixture()
        let gate = PlaybackTestGate()
        await fixture.runtime.holdPlaybackSchedule(gate)
        let frame = try AudioPCMFrame(
            float32: Array(repeating: 0, count: AudioPCMFrame.interleavedSampleCount)
        )
        let play = Task { try await fixture.adapter.play(frame) }
        await gate.waitUntilEntered()
        let stop = Task {
            switch stopKind {
            case 0: await fixture.adapter.stopPlayback()
            case 1: await fixture.adapter.stopNow()
            case 2: await fixture.adapter.setDeafened(true)
            default: await fixture.runtime.emit(event: .configurationChanged)
            }
        }
        await gate.waitUntilCancelled()
        #expect(try await fixture.adapter.play(frame) == false)
        #expect(await fixture.runtime.playbackStopCount() == 0)
        #expect(await fixture.runtime.stopNowCount() == 0)
        await gate.release()
        await stop.value
        #expect(try await play.value == false)
        #expect(await fixture.runtime.activePlaybackCount() == 0)
        #expect(await fixture.adapter.playbackQueueDepth() == 0)
        let expectedState: AudioEngineState = stopKind == 3 ? .configurationChanged : .stopped
        #expect(await fixture.adapter.currentState() == expectedState)
    }

    @Test("playback queue rejects overflow instead of growing unbounded")
    func playbackBackpressure() async throws {
        let fixture = try AudioFixture(maximumPendingPlaybackFrames: 2)
        let frame = try AudioPCMFrame(
            float32: Array(repeating: 0, count: AudioPCMFrame.interleavedSampleCount)
        )
        #expect(try await fixture.adapter.play(frame))
        #expect(try await fixture.adapter.play(frame))
        #expect(try await fixture.adapter.play(frame) == false)
        #expect(await fixture.runtime.playCount() == 2)
        #expect(await fixture.adapter.playbackQueueDepth() == 2)
        #expect(await fixture.adapter.droppedPlaybackFrameCount() == 1)
    }
}

private struct AudioFixture {
    let adapter: AVAudioEngineAdapter
    let runtime: AudioEngineRuntimeSpy

    init(maximumCapturedFrames: Int = 8, maximumPendingPlaybackFrames: Int = 8) throws {
        runtime = AudioEngineRuntimeSpy()
        let policy = FixedMediaPolicy(disabled: false)
        let permission = PermissionProviderSpy(status: .authorized)
        adapter = AVAudioEngineAdapter(
            runtime: runtime,
            permissions: MediaPermissionController(provider: permission, policy: policy),
            policy: policy,
            configuration: .init(
                maximumCapturedFrames: maximumCapturedFrames,
                maximumPendingPlaybackFrames: maximumPendingPlaybackFrames
            )
        )
    }
}

private actor AudioEngineRuntimeSpy: AudioEngineRuntime {
    private var deliver: (@Sendable (UInt64, AudioCaptureRuntimeDelivery) async -> Void)?
    private var eventHandler: (@Sendable (AudioRuntimeEvent) async -> Void)?
    private var starts = 0
    private var captureStops = 0
    private var fullStops = 0
    private var plays = 0
    private var playbackStops = 0
    private var activePlayback = 0
    private var eventInstallGate: PlaybackTestGate?
    private var scheduleGate: PlaybackTestGate?
    private var holdStart = false
    private var failStart = false
    private var heldStartContinuation: CheckedContinuation<Void, Never>?
    private var startObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    func installEventHandler(
        _ handler: @escaping @Sendable (AudioRuntimeEvent) async -> Void
    ) async {
        eventHandler = handler
        if let eventInstallGate { await eventInstallGate.enter() }
    }

    func startCapture(
        generation: UInt64,
        selection: AudioDeviceSelection,
        deliver: @escaping @Sendable (UInt64, AudioCaptureRuntimeDelivery) async -> Void
    ) async throws {
        starts += 1
        resumeSatisfiedStartObservers()
        self.deliver = deliver
        if holdStart {
            holdStart = false
            await withCheckedContinuation { continuation in
                heldStartContinuation = continuation
            }
        }
        if failStart {
            failStart = false
            throw AudioRuntimeSpyError.startFailed
        }
    }

    func schedulePlayback(
        _ frame: AudioPCMFrame,
        selection: AudioDeviceSelection,
        token: UInt64,
        completion: @escaping @Sendable (UInt64) async -> Void
    ) async {
        if let scheduleGate {
            await withTaskCancellationHandler {
                await scheduleGate.enter()
            } onCancel: {
                Task { await scheduleGate.cancelled() }
            }
        }
        plays += 1
        activePlayback += 1
    }

    func stopCapture() { captureStops += 1 }
    func stopPlayback() {
        playbackStops += 1
        activePlayback = 0
    }
    func stopNow() {
        fullStops += 1
        activePlayback = 0
    }

    func holdEventInstallation(_ gate: PlaybackTestGate) { eventInstallGate = gate }
    func holdPlaybackSchedule(_ gate: PlaybackTestGate) { scheduleGate = gate }
    func playbackStopCount() -> Int { playbackStops }
    func activePlaybackCount() -> Int { activePlayback }

    func emit(_ samples: [Float], generation: UInt64) async {
        await deliver?(generation, .samples(samples))
    }

    func emitDroppedSourceBuffers(_ count: Int, generation: UInt64) async {
        await deliver?(generation, .droppedSourceBuffers(count))
    }

    func emit(event: AudioRuntimeEvent) async {
        await eventHandler?(event)
    }

    func startCount() -> Int { starts }
    func captureStopCount() -> Int { captureStops }
    func stopNowCount() -> Int { fullStops }
    func playCount() -> Int { plays }

    func holdNextStart() {
        holdStart = true
    }

    func failNextStart() {
        failStart = true
    }

    func releaseHeldStart() {
        heldStartContinuation?.resume()
        heldStartContinuation = nil
    }

    func waitForStartCount(_ expected: Int) async {
        guard starts < expected else { return }
        await withCheckedContinuation { continuation in
            startObservers.append((expected, continuation))
        }
    }

    private func resumeSatisfiedStartObservers() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expected, continuation) in startObservers {
            if starts >= expected {
                continuation.resume()
            } else {
                remaining.append((expected, continuation))
            }
        }
        startObservers = remaining
    }
}

private enum AudioRuntimeSpyError: Error {
    case startFailed
}

/// Explicit entry, cancellation and release barriers, with no sleeps or yield races.
private actor PlaybackTestGate {
    private var entered = false
    private var isCancelled = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func cancelled() {
        isCancelled = true
        for waiter in cancellationWaiters { waiter.resume() }
        cancellationWaiters.removeAll()
    }

    func waitUntilCancelled() async {
        if !isCancelled { await withCheckedContinuation { cancellationWaiters.append($0) } }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor PermissionProviderSpy: MediaPermissionProviding {
    private let status: MediaAuthorizationStatus
    private let requestResult: MediaAuthorizationStatus
    private var statuses = 0
    private var requests = 0

    init(
        status: MediaAuthorizationStatus,
        requestResult: MediaAuthorizationStatus = .authorized
    ) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus(for kind: MediaPermissionKind) -> MediaAuthorizationStatus {
        statuses += 1
        return status
    }

    func requestAuthorization(for kind: MediaPermissionKind) -> MediaAuthorizationStatus {
        requests += 1
        return requestResult
    }

    func statusCalls() -> Int { statuses }
    func requestCalls() -> Int { requests }
}

private struct FixedMediaPolicy: MediaRuntimePolicyProviding {
    let disabled: Bool
    func mediaDisabled() -> Bool { disabled }
}
