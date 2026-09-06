@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

public struct AVAudioEngineAdapterConfiguration: Equatable, Sendable {
    public let maximumCapturedFrames: Int
    public let maximumPendingCaptureBuffers: Int
    public let maximumPendingPlaybackFrames: Int

    public init(
        maximumCapturedFrames: Int = 64,
        maximumPendingCaptureBuffers: Int = 8,
        maximumPendingPlaybackFrames: Int = 64
    ) {
        self.maximumCapturedFrames = max(1, maximumCapturedFrames)
        self.maximumPendingCaptureBuffers = max(1, maximumPendingCaptureBuffers)
        self.maximumPendingPlaybackFrames = max(1, maximumPendingPlaybackFrames)
    }
}

public enum AudioCaptureRuntimeDelivery: Sendable {
    case samples([Float])
    case droppedSourceBuffers(Int)
}

public enum AudioRuntimeEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded
    case configurationChanged
    case deviceConfigurationChanged
}

public enum AudioEngineState: Equatable, Sendable {
    case stopped
    case startingCapture
    case capturing
    case playbackOnly
    case interrupted
    case configurationChanged
    case failed(String)
}

public protocol AudioEngineRuntime: Sendable {
    func installEventHandler(
        _ handler: @escaping @Sendable (AudioRuntimeEvent) async -> Void
    ) async
    func startCapture(
        generation: UInt64,
        selection: AudioDeviceSelection,
        deliver: @escaping @Sendable (UInt64, AudioCaptureRuntimeDelivery) async -> Void
    ) async throws
    func schedulePlayback(
        _ frame: AudioPCMFrame,
        selection: AudioDeviceSelection,
        token: UInt64,
        completion: @escaping @Sendable (UInt64) async -> Void
    ) async throws
    func stopCapture() async
    func stopPlayback() async
    func stopNow() async
}

/// Explicit, bounded lifecycle boundary around AVAudioEngine.
///
/// Construction, permission queries, and device enumeration never start the engine. Capture only
/// starts after the caller has separately requested permission and invokes `startCapture()`.
public actor AVAudioEngineAdapter {
    private struct CaptureStartOperation: Sendable {
        let generation: UInt64
        let task: Task<UInt64, any Error>
    }

    private struct PendingPlayback: Sendable {
        let token: UInt64
    }

    private let runtime: any AudioEngineRuntime
    private let permissions: MediaPermissionController
    private let policy: any MediaRuntimePolicyProviding
    private let configuration: AVAudioEngineAdapterConfiguration
    private let captureContinuation: AsyncStream<AudioPCMFrame>.Continuation
    private let eventContinuation: AsyncStream<AudioRuntimeEvent>.Continuation

    public nonisolated let capturedFrames: AsyncStream<AudioPCMFrame>
    public nonisolated let runtimeEvents: AsyncStream<AudioRuntimeEvent>

    private var selection = AudioDeviceSelection()
    private var generation: UInt64 = 0
    private var playbackToken: UInt64 = 0
    private var playbackQueue: [PendingPlayback] = []
    private var playbackGeneration: UInt64 = 0
    private var playbackSchedules: [UInt64: Task<Void, any Error>] = [:]
    private var playbackTeardownCount = 0
    private var assembler = DiscordAudioFrameAssembler()
    private var captureStartOperation: CaptureStartOperation?
    private var captureTeardownInProgress = false
    private var state: AudioEngineState = .stopped
    private var muted = false
    private var deafened = false
    private var eventsInstalled = false
    private var captureDropCount = 0
    private var captureIngressDropCount = 0
    private var playbackDropCount = 0

    public init(
        runtime: any AudioEngineRuntime,
        permissions: MediaPermissionController,
        policy: any MediaRuntimePolicyProviding,
        configuration: AVAudioEngineAdapterConfiguration = .init()
    ) {
        self.runtime = runtime
        self.permissions = permissions
        self.policy = policy
        self.configuration = configuration

        let capturePair = AsyncStream<AudioPCMFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(configuration.maximumCapturedFrames)
        )
        capturedFrames = capturePair.stream
        captureContinuation = capturePair.continuation

        let eventPair = AsyncStream<AudioRuntimeEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        runtimeEvents = eventPair.stream
        eventContinuation = eventPair.continuation
    }

    public init(configuration: AVAudioEngineAdapterConfiguration = .init()) {
        let policy = ProcessMediaRuntimePolicy()
        self.init(
            runtime: SystemAVAudioEngineRuntime(
                maximumPendingCaptureBuffers: configuration.maximumPendingCaptureBuffers
            ),
            permissions: MediaPermissionController(
                provider: SystemMediaPermissionProvider(),
                policy: policy
            ),
            policy: policy,
            configuration: configuration
        )
    }

    deinit {
        captureContinuation.finish()
        eventContinuation.finish()
    }

    public func microphoneAuthorizationStatus() async -> MediaAuthorizationStatus {
        await permissions.authorizationStatus(for: .microphone)
    }

    /// This is the only API in the audio boundary that may prompt for microphone access.
    public func requestMicrophoneAuthorization() async throws -> MediaAuthorizationStatus {
        try await permissions.requestAuthorization(for: .microphone)
    }

    public func setDeviceSelection(_ selection: AudioDeviceSelection) throws {
        guard state == .stopped else {
            throw MediaRuntimeError.deviceSelectionRequiresStoppedEngine
        }
        guard selection.input?.supportsInput != false else {
            throw MediaRuntimeError.unsupportedInputDevice
        }
        guard selection.output?.supportsOutput != false else {
            throw MediaRuntimeError.unsupportedOutputDevice
        }
        self.selection = selection
    }

    @discardableResult
    public func startCapture() async throws -> UInt64 {
        guard playbackTeardownCount == 0 else { throw CancellationError() }
        if state == .capturing { return generation }
        if let operation = captureStartOperation {
            return try await operation.task.value
        }
        guard !captureTeardownInProgress else { throw CancellationError() }
        guard !policy.mediaDisabled() else {
            throw MediaRuntimeError.disabledByEnvironment
        }

        generation &+= 1
        let startingGeneration = generation
        assembler.reset()
        state = .startingCapture

        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performCaptureStart(generation: startingGeneration)
        }
        captureStartOperation = CaptureStartOperation(
            generation: startingGeneration,
            task: task
        )

        do {
            let result = try await task.value
            clearCaptureStartOperation(generation: startingGeneration)
            return result
        } catch {
            clearCaptureStartOperation(generation: startingGeneration)
            throw error
        }
    }

    public func stopCapture() async {
        let pendingStart = captureStartOperation
        guard pendingStart != nil
                || state == .startingCapture
                || state == .capturing
                || state == .interrupted
                || state == .configurationChanged
                || isFailedState
        else {
            return
        }
        captureTeardownInProgress = true
        pendingStart?.task.cancel()
        generation &+= 1
        assembler.reset()
        await runtime.stopCapture()
        if let pendingStart {
            _ = try? await pendingStart.task.value
            clearCaptureStartOperation(generation: pendingStart.generation)
        }
        state = playbackQueue.isEmpty ? .stopped : .playbackOnly
        captureTeardownInProgress = false
    }

    /// Stops capture and playback synchronously from the actor's perspective. It never schedules a
    /// restart; a later capture requires another explicit `startCapture()` call.
    public func stopNow() async {
        let pendingPlayback = beginPlaybackTeardown()
        defer { playbackTeardownCount -= 1 }
        captureTeardownInProgress = true
        let pendingStart = captureStartOperation
        pendingStart?.task.cancel()
        generation &+= 1
        assembler.reset()
        // Remove the microphone tap without waiting for a playback runtime
        // that may ignore cancellation. The final stop still follows schedules.
        await runtime.stopCapture()
        for task in pendingPlayback { _ = await task.result }
        await runtime.stopNow()
        if let pendingStart {
            _ = try? await pendingStart.task.value
            clearCaptureStartOperation(generation: pendingStart.generation)
        }
        state = .stopped
        captureTeardownInProgress = false
    }

    @discardableResult
    public func play(_ frame: AudioPCMFrame) async throws -> Bool {
        guard !policy.mediaDisabled() else {
            throw MediaRuntimeError.disabledByEnvironment
        }
        guard !deafened, playbackTeardownCount == 0 else { return false }
        let admittedGeneration = playbackGeneration
        await installEventsIfNeeded()
        guard admittedGeneration == playbackGeneration,
              !deafened, playbackTeardownCount == 0
        else { return false }
        guard playbackQueue.count < configuration.maximumPendingPlaybackFrames else {
            playbackDropCount += 1
            return false
        }
        playbackToken &+= 1
        let token = playbackToken
        playbackQueue.append(PendingPlayback(token: token))
        let selection = selection
        let task = Task { [runtime, weak self] in
            try Task.checkCancellation()
            try await runtime.schedulePlayback(
                frame,
                selection: selection,
                token: token
            ) { [weak self] completedToken in
                await self?.completePlayback(token: completedToken)
            }
        }
        playbackSchedules[token] = task
        defer { playbackSchedules[token] = nil }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard admittedGeneration == playbackGeneration else { return false }
            if state == .stopped, !playbackQueue.isEmpty {
                state = .playbackOnly
            }
            return true
        } catch {
            playbackQueue.removeAll { $0.token == token }
            guard admittedGeneration == playbackGeneration else { return false }
            if error is CancellationError {
                // Canceling this frame does not fail an independent capture session.
                if state == .playbackOnly, playbackQueue.isEmpty { state = .stopped }
                throw error
            }
            state = .failed(Self.describe(error))
            throw error
        }
    }

    public func stopPlayback() async {
        let pendingPlayback = beginPlaybackTeardown()
        defer { playbackTeardownCount -= 1 }
        for task in pendingPlayback { _ = await task.result }
        await runtime.stopPlayback()
        state = state == .capturing ? .capturing : .stopped
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
    }

    public func setDeafened(_ deafened: Bool) async {
        self.deafened = deafened
        if deafened {
            await stopPlayback()
        }
    }

    public func currentState() -> AudioEngineState { state }
    public func currentSelection() -> AudioDeviceSelection { selection }
    public func playbackQueueDepth() -> Int { playbackQueue.count }
    public func droppedCaptureFrameCount() -> Int { captureDropCount }
    public func droppedCaptureSourceBufferCount() -> Int { captureIngressDropCount }
    public func droppedPlaybackFrameCount() -> Int { playbackDropCount }
    public func currentGeneration() -> UInt64 { generation }
    public func isMuted() -> Bool { muted }
    public func isDeafened() -> Bool { deafened }

    private func installEventsIfNeeded() async {
        guard !eventsInstalled else { return }
        eventsInstalled = true
        await runtime.installEventHandler { [weak self] event in
            await self?.receiveRuntimeEvent(event)
        }
    }

    private func performCaptureStart(generation startingGeneration: UInt64) async throws -> UInt64 {
        do {
            try Task.checkCancellation()
            try await permissions.requireMicrophoneAuthorization()
            try Task.checkCancellation()
            await installEventsIfNeeded()
            try Task.checkCancellation()

            try await runtime.startCapture(
                generation: startingGeneration,
                selection: selection
            ) { [weak self] callbackGeneration, delivery in
                await self?.receiveCaptureDelivery(delivery, generation: callbackGeneration)
            }
            try Task.checkCancellation()
            guard generation == startingGeneration, state == .startingCapture else {
                throw CancellationError()
            }
            state = .capturing
            return startingGeneration
        } catch {
            // `SystemAVAudioEngineRuntime` installs the input tap before `engine.start()` can throw.
            // Rolling the runtime back here makes startup transactional for injected runtimes too.
            await runtime.stopCapture()
            if generation == startingGeneration, state == .startingCapture {
                generation &+= 1
                state = .failed(Self.describe(error))
            }
            throw error
        }
    }

    private func clearCaptureStartOperation(generation completedGeneration: UInt64) {
        guard captureStartOperation?.generation == completedGeneration else { return }
        captureStartOperation = nil
    }

    private var isFailedState: Bool {
        if case .failed = state { return true }
        return false
    }

    private func receiveCaptureDelivery(
        _ delivery: AudioCaptureRuntimeDelivery,
        generation callbackGeneration: UInt64
    ) {
        switch delivery {
        case let .samples(samples):
            receiveCaptured(samples, generation: callbackGeneration)
        case let .droppedSourceBuffers(count):
            guard callbackGeneration == generation, count > 0 else { return }
            captureIngressDropCount += count
        }
    }

    private func receiveCaptured(_ samples: [Float], generation callbackGeneration: UInt64) {
        guard state == .capturing || state == .startingCapture,
              callbackGeneration == generation,
              !muted
        else { return }

        do {
            for frame in try assembler.append(interleavedFloat32: samples) {
                switch captureContinuation.yield(frame) {
                case .enqueued:
                    break
                case .dropped:
                    captureDropCount += 1
                case .terminated:
                    return
                @unknown default:
                    return
                }
            }
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private func receiveRuntimeEvent(_ event: AudioRuntimeEvent) async {
        _ = eventContinuation.yield(event)
        switch event {
        case .interruptionEnded:
            // No automatic restart: the operator must explicitly start capture again.
            return
        case .interruptionBegan:
            state = .interrupted
        case .configurationChanged, .deviceConfigurationChanged:
            state = .configurationChanged
        }
        captureStartOperation?.task.cancel()
        generation &+= 1
        assembler.reset()
        let pendingPlayback = beginPlaybackTeardown()
        defer { playbackTeardownCount -= 1 }
        await runtime.stopCapture()
        for task in pendingPlayback { _ = await task.result }
        await runtime.stopNow()
    }

    private func beginPlaybackTeardown() -> [Task<Void, any Error>] {
        playbackGeneration &+= 1
        playbackTeardownCount += 1
        playbackQueue.removeAll(keepingCapacity: true)
        let pending = Array(playbackSchedules.values)
        for task in pending { task.cancel() }
        // Keep admission closed until all schedules drain and the runtime is
        // stopped. A cancellation-ignoring runtime must not schedule after stop.
        return pending
    }

    private func completePlayback(token: UInt64) {
        playbackQueue.removeAll { $0.token == token }
        if playbackQueue.isEmpty, state == .playbackOnly {
            state = .stopped
        }
    }

    private static func describe(_ error: any Error) -> String {
        String(describing: error)
    }
}

/// Preallocated handoff between Core Audio's real-time callback and the async conversion worker.
/// At most `capacity` source buffers can be owned at once; overload drops the newest callback.
final class BoundedAudioCaptureIngress: @unchecked Sendable {
    let slots: AsyncStream<Int>

    private let continuation: AsyncStream<Int>.Continuation
    private let lock = NSLock()
    private let format: AVAudioFormat
    private let buffers: [AVAudioPCMBuffer]
    private var freeSlots: [Int]
    private var droppedCount = 0

    init?(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, capacity: Int) {
        let boundedCapacity = max(1, capacity)
        var allocated: [AVAudioPCMBuffer] = []
        allocated.reserveCapacity(boundedCapacity)
        for _ in 0..<boundedCapacity {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCapacity
            ) else { return nil }
            allocated.append(buffer)
        }

        let pair = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingOldest(boundedCapacity)
        )
        self.format = format
        buffers = allocated
        freeSlots = Array(allocated.indices.reversed())
        slots = pair.stream
        continuation = pair.continuation
    }

    func enqueue(copying source: AVAudioPCMBuffer) {
        guard let slot = leaseSlot() else {
            recordDrop()
            return
        }
        guard copy(source, into: buffers[slot]) else {
            release(slot: slot)
            recordDrop()
            return
        }

        switch continuation.yield(slot) {
        case .enqueued:
            break
        case let .dropped(droppedSlot):
            release(slot: droppedSlot)
            recordDrop()
        case .terminated:
            release(slot: slot)
        @unknown default:
            release(slot: slot)
            recordDrop()
        }
    }

    func finish() {
        continuation.finish()
    }

    func buffer(for slot: Int) -> AVAudioPCMBuffer? {
        buffers.indices.contains(slot) ? buffers[slot] : nil
    }

    func release(slot: Int) {
        lock.lock()
        freeSlots.append(slot)
        lock.unlock()
    }

    func takeDroppedCount() -> Int {
        lock.lock()
        let count = droppedCount
        droppedCount = 0
        lock.unlock()
        return count
    }

    var pendingBufferCount: Int {
        lock.lock()
        let count = buffers.count - freeSlots.count
        lock.unlock()
        return count
    }

    private func leaseSlot() -> Int? {
        lock.lock()
        let slot = freeSlots.popLast()
        lock.unlock()
        return slot
    }

    private func recordDrop() {
        lock.lock()
        droppedCount += 1
        lock.unlock()
    }

    private func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer) -> Bool {
        guard source.format.sampleRate == format.sampleRate,
              source.format.channelCount == format.channelCount,
              source.format.commonFormat == format.commonFormat,
              source.format.isInterleaved == format.isInterleaved,
              source.frameLength <= destination.frameCapacity
        else { return false }

        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else { return false }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData,
                  sourceBuffer.mDataByteSize <= destinationBuffer.mDataByteSize
            else { return false }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffer.mDataByteSize = sourceBuffer.mDataByteSize
            destinationBuffers[index] = destinationBuffer
        }
        return true
    }
}

actor SystemAVAudioEngineRuntime: AudioEngineRuntime {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat
    private let maximumPendingCaptureBuffers: Int
    private var tapInstalled = false
    private var playbackConnected = false
    private var captureIngress: BoundedAudioCaptureIngress?
    private var captureDrainTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (AudioRuntimeEvent) async -> Void)?
    private var configurationTask: Task<Void, Never>?

    init(maximumPendingCaptureBuffers: Int = 8) {
        self.maximumPendingCaptureBuffers = max(1, maximumPendingCaptureBuffers)
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioPCMFrame.sampleRate,
            channels: AVAudioChannelCount(AudioPCMFrame.channelCount),
            interleaved: false
        )!
        engine.attach(player)
    }

    deinit {
        configurationTask?.cancel()
        captureIngress?.finish()
        captureDrainTask?.cancel()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        player.stop()
        engine.stop()
    }

    func installEventHandler(
        _ handler: @escaping @Sendable (AudioRuntimeEvent) async -> Void
    ) {
        eventHandler = handler
        guard configurationTask == nil else { return }
        configurationTask = Task { [weak self, engine] in
            for await _ in NotificationCenter.default.notifications(
                named: .AVAudioEngineConfigurationChange,
                object: engine
            ) {
                guard !Task.isCancelled else { return }
                await self?.configurationChanged()
            }
        }
    }

    func startCapture(
        generation: UInt64,
        selection: AudioDeviceSelection,
        deliver: @escaping @Sendable (UInt64, AudioCaptureRuntimeDelivery) async -> Void
    ) async throws {
        try applyInputDevice(selection.input)
        guard !tapInstalled, captureIngress == nil, captureDrainTask == nil else {
            throw MediaRuntimeError.runtimeFailure("Capture is already installed")
        }

        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0,
              sourceFormat.channelCount > 0,
              let ingress = BoundedAudioCaptureIngress(
                  format: sourceFormat,
                  frameCapacity: 4_096,
                  capacity: maximumPendingCaptureBuffers
              )
        else {
            throw MediaRuntimeError.runtimeFailure("The selected input format is unavailable")
        }

        captureIngress = ingress
        let drainTask = Task { [weak self, ingress] in
            guard let self else { return }
            await self.drainCaptureIngress(
                ingress,
                sourceFormat: sourceFormat,
                generation: generation,
                deliver: deliver
            )
        }
        captureDrainTask = drainTask

        do {
            try input.__installTap(
                onBus: 0,
                bufferSize: 960,
                format: sourceFormat,
                error: ()
            ) { buffer, _ in
                ingress.enqueue(copying: buffer)
            }
            tapInstalled = true
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            ingress.finish()
            drainTask.cancel()
            await drainTask.value
            captureIngress = nil
            captureDrainTask = nil
            throw error
        }
    }

    func schedulePlayback(
        _ frame: AudioPCMFrame,
        selection: AudioDeviceSelection,
        token: UInt64,
        completion: @escaping @Sendable (UInt64) async -> Void
    ) async throws {
        try applyOutputDevice(selection.output)
        guard let buffer = AVAudioPCMBridge.appleBuffer(from: frame, format: playbackFormat) else {
            throw AudioPCMFrameError.incorrectSampleCount(
                actual: frame.float32Samples.count,
                expected: AudioPCMFrame.interleavedSampleCount
            )
        }
        if !playbackConnected {
            try engine.connectNode(player, to: engine.mainMixerNode, format: playbackFormat)
            playbackConnected = true
        }
        if !engine.isRunning {
            try engine.start()
        }
        if !player.isPlaying {
            try player.playAudio()
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { await completion(token) }
        }
    }

    func stopCapture() async {
        let ingress = captureIngress
        let drainTask = captureDrainTask
        captureIngress = nil
        captureDrainTask = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        ingress?.finish()
        drainTask?.cancel()
        if let drainTask {
            await drainTask.value
        }
        if !player.isPlaying {
            engine.stop()
        }
    }

    func stopPlayback() {
        player.stop()
        if !tapInstalled {
            engine.stop()
        }
    }

    func stopNow() async {
        let ingress = captureIngress
        let drainTask = captureDrainTask
        captureIngress = nil
        captureDrainTask = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        ingress?.finish()
        drainTask?.cancel()
        if let drainTask {
            await drainTask.value
        }
        player.stop()
        engine.stop()
    }

    private func drainCaptureIngress(
        _ ingress: BoundedAudioCaptureIngress,
        sourceFormat: AVAudioFormat,
        generation: UInt64,
        deliver: @escaping @Sendable (UInt64, AudioCaptureRuntimeDelivery) async -> Void
    ) async {
        guard let converter = ReusableAVAudioPCMConverter(sourceFormat: sourceFormat) else {
            ingress.finish()
            return
        }

        for await slot in ingress.slots {
            if Task.isCancelled { break }

            let dropped = ingress.takeDroppedCount()
            if dropped > 0 {
                await deliver(generation, .droppedSourceBuffers(dropped))
            }

            let samples = ingress.buffer(for: slot).flatMap { converter.normalizedSamples(from: $0) }
            ingress.release(slot: slot)
            if let samples {
                await deliver(generation, .samples(samples))
            }
        }

        let dropped = ingress.takeDroppedCount()
        if dropped > 0, !Task.isCancelled {
            await deliver(generation, .droppedSourceBuffers(dropped))
        }
    }

    private func configurationChanged() async {
        await eventHandler?(.configurationChanged)
    }

    private func applyInputDevice(_ device: AudioDeviceSnapshot?) throws {
        guard let device else { return }
        try engine.inputNode.withAudioUnit { audioUnit in
            try setCurrentDevice(device.id, on: audioUnit)
        }
    }

    private func applyOutputDevice(_ device: AudioDeviceSnapshot?) throws {
        guard let device else { return }
        try engine.outputNode.withAudioUnit { audioUnit in
            try setCurrentDevice(device.id, on: audioUnit)
        }
    }

    private func setCurrentDevice(_ deviceID: AudioObjectID, on audioUnit: AudioUnit?) throws {
        guard let audioUnit else {
            throw MediaRuntimeError.runtimeFailure("Audio unit is unavailable")
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw MediaRuntimeError.runtimeFailure("Core Audio device selection failed (OSStatus \(status))")
        }
    }
}

private final class ReusableAVAudioPCMConverter {
    private let converter: AVAudioConverter
    private let converted: AVAudioPCMBuffer

    init?(sourceFormat: AVAudioFormat) {
        guard sourceFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: AudioPCMFrame.sampleRate,
                  channels: AVAudioChannelCount(AudioPCMFrame.channelCount),
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let converted = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: AVAudioFrameCount(
                      ceil(4_096 * AudioPCMFrame.sampleRate / sourceFormat.sampleRate)
                  ) + 32
              )
        else { return nil }
        self.converter = converter
        self.converted = converted
    }

    func normalizedSamples(from sourceBuffer: AVAudioPCMBuffer) -> [Float]? {
        guard sourceBuffer.frameLength > 0 else { return nil }
        converter.reset()
        converted.frameLength = 0
        var conversionError: NSError?
        var supplied = false
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard conversionError == nil,
              status != .error,
              converted.frameLength > 0,
              let channels = converted.floatChannelData
        else { return nil }

        let count = Int(converted.frameLength)
        var interleaved: [Float] = []
        interleaved.reserveCapacity(count * AudioPCMFrame.channelCount)
        for index in 0..<count {
            interleaved.append(channels[0][index])
            interleaved.append(channels[1][index])
        }
        return interleaved
    }
}

private enum AVAudioPCMBridge {
    static func appleBuffer(from frame: AudioPCMFrame, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard frame.frameCount == AudioPCMFrame.framesPerChannel,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(AudioPCMFrame.framesPerChannel)
              ),
              let channels = buffer.floatChannelData
        else { return nil }

        let samples = frame.float32Samples
        guard samples.count == AudioPCMFrame.interleavedSampleCount else { return nil }
        buffer.frameLength = AVAudioFrameCount(AudioPCMFrame.framesPerChannel)
        for index in 0..<AudioPCMFrame.framesPerChannel {
            channels[0][index] = samples[index * AudioPCMFrame.channelCount]
            channels[1][index] = samples[index * AudioPCMFrame.channelCount + 1]
        }
        return buffer
    }
}
