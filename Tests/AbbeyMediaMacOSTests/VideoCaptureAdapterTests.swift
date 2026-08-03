import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Testing
@testable import AbbeyMediaMacOS

@Suite("Video capture adapter")
struct VideoCaptureAdapterTests {
    @Test("disabled mode fails closed before prompts discovery or runtime start")
    func disabledFailsClosed() async {
        let fixture = VideoFixture(disabled: true)

        await #expect(throws: VideoCaptureError.disabledByEnvironment) {
            try await fixture.adapter.requestCameraAuthorization()
        }
        await #expect(throws: VideoCaptureError.disabledByEnvironment) {
            try await fixture.adapter.refreshSources()
        }
        await #expect(throws: VideoCaptureError.disabledByEnvironment) {
            try await fixture.adapter.startCapture()
        }

        #expect(await fixture.permissions.statusCalls().isEmpty)
        #expect(await fixture.permissions.requestCalls().isEmpty)
        #expect(await fixture.sources.fetchCount() == 0)
        #expect(await fixture.runtime.startCount() == 0)
    }

    @Test("camera and screen prompts are explicit and independently attributed")
    func explicitPermissionRequests() async throws {
        let fixture = VideoFixture(
            statuses: [.camera: .notDetermined, .screen: .notDetermined],
            requestResults: [.camera: .authorized, .screen: .denied]
        )

        #expect(try await fixture.adapter.requestCameraAuthorization() == .authorized)
        #expect(try await fixture.adapter.requestScreenAuthorization() == .denied)
        #expect(await fixture.permissions.requestCalls() == [.camera, .screen])
        #expect(await fixture.sources.fetchCount() == 0)
    }

    @Test("discovery includes only authorized source classes and never exposes platform IDs")
    func discoveryIsAuthorizedAndRedacted() async throws {
        let secret = "camera-hardware-id-that-must-not-escape"
        let camera = VideoCaptureSourceSnapshot(
            kind: .camera,
            title: "Studio Camera",
            detail: "Camera",
            systemHandle: .camera(uniqueID: secret)
        )
        let display = VideoCaptureSourceSnapshot(kind: .display, title: "Main Display")
        let fixture = VideoFixture(
            statuses: [.camera: .authorized, .screen: .denied],
            availableSources: [camera, display]
        )

        let refreshed = try await fixture.adapter.refreshSources()
        #expect(refreshed == [camera])
        #expect(await fixture.sources.lastFlags() == SourceRequestFlags(cameras: true, screens: false))
        #expect(!String(describing: camera).contains(secret))
        #expect(!String(reflecting: camera).contains(secret))

        try await fixture.adapter.selectSource(id: camera.id)
        let snapshot = await fixture.adapter.statusSnapshot()
        #expect(snapshot.selectedSource == camera.metadata)
    }

    @Test("concurrent starts share one operation and one generation")
    func concurrentStartsAreSerialized() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        try await fixture.prepareCamera()
        await fixture.runtime.holdNextStart()

        let first = Task { try await fixture.adapter.startCapture() }
        await fixture.runtime.waitForStartCount(1)
        let second = Task { try await fixture.adapter.startCapture() }
        for _ in 0..<20 { await Task.yield() }

        #expect(await fixture.runtime.startCount() == 1)
        await fixture.runtime.releaseHeldStart()
        #expect(try await first.value == second.value)
        #expect(await fixture.adapter.statusSnapshot().state == .capturing)
    }

    @Test("permission revoked after selection blocks runtime startup")
    func revokedPermissionBlocksStart() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        try await fixture.prepareCamera()
        await fixture.permissions.setStatus(.denied, for: .camera)
        var events = fixture.adapter.captureEvents.makeAsyncIterator()

        await #expect(
            throws: VideoCaptureError.permissionRequired(.camera, .denied)
        ) {
            try await fixture.adapter.startCapture()
        }
        #expect(await fixture.runtime.startCount() == 0)
        #expect(await fixture.runtime.stopCount() == 1)
        #expect(await nextStatus(from: &events)?.state == .starting)
        let failed = try #require(await nextStatus(from: &events))
        guard case .failed = failed.state else {
            Issue.record("Expected a generation-scoped failed capture status")
            return
        }
        #expect(failed.generation > 0)
    }

    @Test("both frame queues are bounded and account for independent drops")
    func queuesAreBounded() async throws {
        let fixture = VideoFixture(
            statuses: [.camera: .authorized],
            configuration: .init(maximumPendingSourceFrames: 2, maximumCapturedFrames: 2)
        )
        try await fixture.prepareCamera()
        let generation = try await fixture.adapter.startCapture()
        for marker in UInt8(1)...3 {
            await fixture.runtime.emit(try frame(marker: marker), generation: generation)
        }
        await fixture.runtime.emitDropped(4, generation: generation)

        let snapshot = await fixture.adapter.statusSnapshot()
        #expect(snapshot.droppedConsumerFrames == 1)
        #expect(snapshot.droppedSourceFrames == 4)
        var iterator = fixture.adapter.captureEvents.makeAsyncIterator()
        #expect(await nextFrame(from: &iterator)?.frame.bytes.first == 2)
        #expect(await nextFrame(from: &iterator)?.frame.bytes.first == 3)

        await fixture.adapter.stopCapture()
        await fixture.runtime.emit(try frame(marker: 9), generation: generation)
        await fixture.runtime.emitDropped(9, generation: generation)
        let stopped = await fixture.adapter.statusSnapshot()
        #expect(stopped.state == .stopped)
        #expect(stopped.droppedSourceFrames == 4)
        #expect(stopped.droppedConsumerFrames == 1)
    }

    @Test("A status event accounts for any buffered frame it evicts")
    func statusEvictionCountsDroppedFrame() async throws {
        let fixture = VideoFixture(
            statuses: [.camera: .authorized],
            configuration: .init(maximumPendingSourceFrames: 2, maximumCapturedFrames: 2)
        )
        try await fixture.prepareCamera()
        let generation = try await fixture.adapter.startCapture()
        await fixture.runtime.emit(try frame(marker: 1), generation: generation)
        await fixture.runtime.emit(try frame(marker: 2), generation: generation)
        #expect(await fixture.adapter.statusSnapshot().droppedConsumerFrames == 0)

        await fixture.adapter.stopCapture()

        #expect(await fixture.adapter.statusSnapshot().droppedConsumerFrames == 1)
        var events = fixture.adapter.captureEvents.makeAsyncIterator()
        #expect(await nextFrame(from: &events)?.frame.bytes.first == 2)
        #expect(await nextStatus(from: &events)?.state == .stopped)
    }

    @Test("pre-actor pixel queue is bounded and produces an owned byte copy")
    func pixelIngressAndOwnership() async throws {
        var optionalBuffer: CVPixelBuffer?
        #expect(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_32BGRA,
                nil,
                &optionalBuffer
            ) == kCVReturnSuccess
        )
        let pixelBuffer = try #require(optionalBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 7, byteCount)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let ingress = BoundedVideoFrameIngress(capacity: 2)
        ingress.enqueue(pixelBuffer: pixelBuffer, presentationTime: CMTime(value: 1, timescale: 10))
        ingress.enqueue(pixelBuffer: pixelBuffer, presentationTime: CMTime(value: 2, timescale: 10))
        ingress.enqueue(pixelBuffer: pixelBuffer, presentationTime: CMTime(value: 3, timescale: 10))
        #expect(ingress.pendingFrameCount == 2)
        #expect(ingress.takeDroppedCount() == 1)

        var iterator = ingress.frames.makeAsyncIterator()
        let sample = try #require(await iterator.next())
        ingress.didConsume()
        let owned = try #require(SystemVideoCaptureRuntime.ownedFrame(from: sample))
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 9, byteCount)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        #expect(owned.bytes.first == 7)
        #expect(owned.presentationTimeNanoseconds > 0)
        ingress.finish()
    }

    @Test("screen lock is a kill event and capture never auto restarts")
    func interruptionStopsWithoutRestart() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        try await fixture.prepareCamera()
        let generation = try await fixture.adapter.startCapture()

        await fixture.runtime.emit(event: .screenLocked)
        #expect(await fixture.adapter.statusSnapshot().state == .interrupted)
        #expect(await fixture.runtime.stopNowCount() == 1)
        #expect(await fixture.runtime.startCount() == 1)

        await fixture.runtime.emit(try frame(marker: 8), generation: generation)
        #expect(await fixture.runtime.startCount() == 1)
    }

    @Test("selected source removal stops capture and preserves only visible metadata")
    func sourceRemovalStopsCapture() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        let source = try await fixture.prepareCamera()
        _ = try await fixture.adapter.startCapture()

        await fixture.runtime.emit(event: .sourceRemoved(UUID()))
        #expect(await fixture.runtime.stopNowCount() == 0)
        await fixture.runtime.emit(event: .sourceRemoved(source.id))
        let snapshot = await fixture.adapter.statusSnapshot()
        #expect(snapshot.state == .sourceUnavailable)
        #expect(snapshot.selectedSource == source.metadata)
        #expect(await fixture.runtime.stopNowCount() == 1)
        #expect(await fixture.runtime.startCount() == 1)
    }

    @Test("Every terminal lifecycle path publishes a generation-scoped status")
    func terminalLifecycleEventsArePublished() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        let source = try await fixture.prepareCamera()
        var events = fixture.adapter.captureEvents.makeAsyncIterator()
        let lifecycleEvents: [(VideoCaptureRuntimeEvent, VideoCaptureState)] = [
            (.sourceRemoved(source.id), .sourceUnavailable),
            (.screenLocked, .interrupted),
            (.systemSuspended, .interrupted),
            (.interrupted, .interrupted),
            (.configurationChanged, .interrupted)
        ]

        for (lifecycleEvent, expectedState) in lifecycleEvents {
            let captureGeneration = try await fixture.adapter.startCapture()
            #expect(await nextStatus(from: &events)?.state == .starting)
            #expect(await nextStatus(from: &events)?.state == .capturing)

            await fixture.runtime.emit(event: lifecycleEvent, generation: captureGeneration)
            let terminal = try #require(await nextStatus(from: &events))
            #expect(terminal.state == expectedState)
            #expect(terminal.generation > captureGeneration)

            await fixture.adapter.stopCapture()
            #expect(await nextStatus(from: &events)?.state == .stopped)
        }
    }

    @Test("Terminal invalidation is published before framework teardown completes")
    func terminalStatusPrecedesSlowRuntimeStop() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        try await fixture.prepareCamera()
        var events = fixture.adapter.captureEvents.makeAsyncIterator()
        let generation = try await fixture.adapter.startCapture()
        #expect(await nextStatus(from: &events)?.state == .starting)
        #expect(await nextStatus(from: &events)?.state == .capturing)
        await fixture.runtime.holdNextStopNow()

        let lifecycle = Task {
            await fixture.runtime.emit(event: .screenLocked, generation: generation)
        }
        await fixture.runtime.waitForStopNowCount(1)

        let terminal = try #require(await nextStatus(from: &events))
        #expect(terminal.state == .interrupted)
        #expect(terminal.generation > generation)

        await fixture.runtime.releaseHeldStopNow()
        await lifecycle.value
    }

    @Test("operator kill switch explicitly stops the runtime")
    func killSwitch() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        try await fixture.prepareCamera()
        _ = try await fixture.adapter.startCapture()

        await fixture.adapter.killSwitch()
        #expect(await fixture.adapter.statusSnapshot().state == .stopped)
        #expect(await fixture.runtime.stopNowCount() == 1)
        #expect(await fixture.runtime.startCount() == 1)
    }

    @Test("stale lifecycle callbacks cannot terminate a newer capture generation")
    func staleLifecycleGenerationIsIgnored() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        try await fixture.prepareCamera()
        let firstGeneration = try await fixture.adapter.startCapture()
        await fixture.adapter.stopCapture()
        let currentGeneration = try await fixture.adapter.startCapture()
        #expect(currentGeneration != firstGeneration)

        await fixture.runtime.emit(event: .interrupted, generation: firstGeneration)

        #expect(await fixture.adapter.statusSnapshot().state == .capturing)
        #expect(await fixture.adapter.statusSnapshot().generation == currentGeneration)
        #expect(await fixture.runtime.stopNowCount() == 0)
    }

    @Test("global lifecycle events are inert after capture stops")
    func idleLifecycleEventsAreIgnored() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        try await fixture.prepareCamera()
        let generation = try await fixture.adapter.startCapture()
        await fixture.adapter.stopCapture()

        await fixture.runtime.emit(event: .screenLocked, generation: generation)
        await fixture.runtime.emit(event: .systemSuspended, generation: generation)
        await fixture.runtime.emit(event: .configurationChanged, generation: generation)

        #expect(await fixture.adapter.statusSnapshot().state == .stopped)
        #expect(await fixture.runtime.stopNowCount() == 0)
    }

    @Test("camera notifications are accepted only from the owned capture session")
    func cameraNotificationsAreSessionScoped() {
        let owned = AVCaptureSession()
        let unrelated = AVCaptureSession()

        #expect(SystemVideoCaptureRuntime.isOwnedCameraSessionNotification(
            sessionIdentity: ObjectIdentifier(owned),
            cameraSession: owned
        ))
        #expect(!SystemVideoCaptureRuntime.isOwnedCameraSessionNotification(
            sessionIdentity: ObjectIdentifier(unrelated),
            cameraSession: owned
        ))
        #expect(!SystemVideoCaptureRuntime.isOwnedCameraSessionNotification(
            sessionIdentity: ObjectIdentifier(owned),
            cameraSession: nil
        ))
    }

    @Test("refresh preserves a selected system source through ephemeral provider IDs")
    func refreshReconcilesSelectedSource() async throws {
        let secretIdentity = "stable-camera-system-identity"
        let first = VideoCaptureSourceSnapshot(
            id: UUID(),
            kind: .camera,
            title: "Studio Camera",
            systemHandle: .camera(uniqueID: secretIdentity)
        )
        let rediscovered = VideoCaptureSourceSnapshot(
            id: UUID(),
            kind: .camera,
            title: "Studio Camera (renamed)",
            systemHandle: .camera(uniqueID: secretIdentity)
        )
        let fixture = VideoFixture(
            statuses: [.camera: .authorized],
            availableSources: [first]
        )
        let initial = try await fixture.adapter.refreshSources()
        try await fixture.adapter.selectSource(id: try #require(initial.first).id)
        await fixture.sources.setSources([rediscovered])

        let refreshed = try await fixture.adapter.refreshSources()
        let reconciled = try #require(refreshed.first)
        let status = await fixture.adapter.statusSnapshot()

        #expect(reconciled.id == first.id)
        #expect(reconciled.title == rediscovered.title)
        #expect(status.selectedSource == reconciled.metadata)
        #expect(!String(describing: reconciled).contains(secretIdentity))
        #expect(!String(reflecting: reconciled).contains(secretIdentity))
    }

    @Test("active capture rejects source refresh before discovery")
    func activeRefreshIsRejected() async throws {
        let fixture = VideoFixture(statuses: [.camera: .authorized])
        try await fixture.prepareCamera()
        _ = try await fixture.adapter.startCapture()

        await #expect(throws: VideoCaptureError.sourceRefreshRequiresStoppedCapture) {
            try await fixture.adapter.refreshSources()
        }
        #expect(await fixture.sources.fetchCount() == 1)
        #expect(await fixture.adapter.statusSnapshot().state == .capturing)
    }

    @Test("only complete ScreenCaptureKit frames enter the bounded frame queue")
    func screenFrameStatusFiltering() throws {
        let pixelBuffer = try makePixelBuffer(marker: 5)
        let ingress = BoundedVideoFrameIngress(capacity: 4)
        let lifecycle = ScreenLifecycleRecorder()
        let delegate = ScreenCaptureOutputDelegate(
            ingress: ingress,
            generation: 41
        ) { generation, event in
            lifecycle.record(generation: generation, event: event)
        }

        for status in [SCFrameStatus.idle, .blank, .started] {
            delegate.handle(status: status, pixelBuffer: pixelBuffer, presentationTime: .zero)
        }
        delegate.handle(status: nil, pixelBuffer: pixelBuffer, presentationTime: .zero)
        #expect(ingress.pendingFrameCount == 0)

        delegate.handle(status: .suspended, pixelBuffer: pixelBuffer, presentationTime: .zero)
        delegate.handle(status: .stopped, pixelBuffer: pixelBuffer, presentationTime: .zero)
        #expect(ingress.pendingFrameCount == 0)
        #expect(lifecycle.events == [
            ScreenLifecycleRecord(generation: 41, event: .suspended),
            ScreenLifecycleRecord(generation: 41, event: .stopped)
        ])

        delegate.handle(status: .complete, pixelBuffer: pixelBuffer, presentationTime: .zero)
        #expect(ingress.pendingFrameCount == 1)
        ingress.finish()
    }

    private func frame(marker: UInt8) throws -> OwnedVideoFrame {
        try OwnedVideoFrame(
            width: 1,
            height: 1,
            bytesPerRow: 4,
            presentationTimeNanoseconds: UInt64(marker),
            bytes: Data(repeating: marker, count: 4)
        )
    }

    private func makePixelBuffer(marker: UInt8) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        #expect(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_32BGRA,
                nil,
                &optionalBuffer
            ) == kCVReturnSuccess
        )
        let pixelBuffer = try #require(optionalBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(marker), byteCount)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func nextStatus(
        from iterator: inout AsyncStream<VideoCaptureEvent>.Iterator
    ) async -> VideoCaptureStatusSnapshot? {
        while let event = await iterator.next() {
            if case let .status(status) = event { return status }
        }
        return nil
    }

    private func nextFrame(
        from iterator: inout AsyncStream<VideoCaptureEvent>.Iterator
    ) async -> (generation: UInt64, frame: OwnedVideoFrame)? {
        while let event = await iterator.next() {
            if case let .frame(generation, frame) = event { return (generation, frame) }
        }
        return nil
    }
}

private struct VideoFixture {
    let adapter: VideoCaptureAdapter
    let sources: VideoSourceProviderSpy
    let runtime: VideoRuntimeSpy
    let permissions: VideoPermissionProviderSpy

    init(
        disabled: Bool = false,
        statuses: [MediaPermissionKind: MediaAuthorizationStatus] = [:],
        requestResults: [MediaPermissionKind: MediaAuthorizationStatus] = [:],
        availableSources: [VideoCaptureSourceSnapshot]? = nil,
        configuration: VideoCaptureAdapterConfiguration = .init()
    ) {
        let fallback = [VideoCaptureSourceSnapshot(kind: .camera, title: "Test Camera")]
        sources = VideoSourceProviderSpy(sources: availableSources ?? fallback)
        runtime = VideoRuntimeSpy()
        permissions = VideoPermissionProviderSpy(statuses: statuses, requestResults: requestResults)
        let policy = VideoPolicy(disabled: disabled)
        adapter = VideoCaptureAdapter(
            sourceProvider: sources,
            runtime: runtime,
            permissions: MediaPermissionController(provider: permissions, policy: policy),
            policy: policy,
            configuration: configuration
        )
    }

    @discardableResult
    func prepareCamera() async throws -> VideoCaptureSourceSnapshot {
        let sources = try await adapter.refreshSources()
        let camera = try #require(sources.first(where: { $0.kind == .camera }))
        try await adapter.selectSource(id: camera.id)
        return camera
    }
}

private struct SourceRequestFlags: Equatable, Sendable {
    let cameras: Bool
    let screens: Bool
}

private struct ScreenLifecycleRecord: Equatable, Sendable {
    let generation: UInt64
    let event: ScreenCaptureFrameLifecycle
}

private final class ScreenLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScreenLifecycleRecord] = []

    var events: [ScreenLifecycleRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(generation: UInt64, event: ScreenCaptureFrameLifecycle) {
        lock.lock()
        storage.append(ScreenLifecycleRecord(generation: generation, event: event))
        lock.unlock()
    }
}

private actor VideoSourceProviderSpy: VideoCaptureSourceProviding {
    private var sources: [VideoCaptureSourceSnapshot]
    private var calls: [SourceRequestFlags] = []

    init(sources: [VideoCaptureSourceSnapshot]) {
        self.sources = sources
    }

    func sourceSnapshots(
        includeCameras: Bool,
        includeScreens: Bool
    ) -> [VideoCaptureSourceSnapshot] {
        calls.append(SourceRequestFlags(cameras: includeCameras, screens: includeScreens))
        return sources.filter { source in
            source.kind == .camera ? includeCameras : includeScreens
        }
    }

    func fetchCount() -> Int { calls.count }
    func lastFlags() -> SourceRequestFlags? { calls.last }
    func setSources(_ sources: [VideoCaptureSourceSnapshot]) { self.sources = sources }
}

private actor VideoRuntimeSpy: VideoCaptureRuntime {
    private var handler: (@Sendable (UInt64, VideoCaptureRuntimeEvent) async -> Void)?
    private var deliver: (@Sendable (UInt64, VideoCaptureRuntimeDelivery) async -> Void)?
    private var lastStartedGeneration: UInt64?
    private var starts = 0
    private var stops = 0
    private var fullStops = 0
    private var holdStart = false
    private var heldStartContinuation: CheckedContinuation<Void, Never>?
    private var startObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var holdStopNow = false
    private var heldStopNowContinuation: CheckedContinuation<Void, Never>?
    private var stopNowObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    func installEventHandler(
        _ handler: @escaping @Sendable (UInt64, VideoCaptureRuntimeEvent) async -> Void
    ) {
        self.handler = handler
    }

    func startCapture(
        generation: UInt64,
        source: VideoCaptureSourceSnapshot,
        deliver: @escaping @Sendable (UInt64, VideoCaptureRuntimeDelivery) async -> Void
    ) async {
        starts += 1
        lastStartedGeneration = generation
        self.deliver = deliver
        resumeObservers()
        if holdStart {
            holdStart = false
            await withCheckedContinuation { continuation in
                heldStartContinuation = continuation
            }
        }
    }

    func stopCapture() { stops += 1 }
    func stopNow() async {
        fullStops += 1
        resumeStopNowObservers()
        if holdStopNow {
            holdStopNow = false
            await withCheckedContinuation { continuation in
                heldStopNowContinuation = continuation
            }
        }
    }

    func emit(_ frame: OwnedVideoFrame, generation: UInt64) async {
        await deliver?(generation, .frame(frame))
    }

    func emitDropped(_ count: Int, generation: UInt64) async {
        await deliver?(generation, .droppedSourceFrames(count))
    }

    func emit(event: VideoCaptureRuntimeEvent) async {
        guard let lastStartedGeneration else { return }
        await handler?(lastStartedGeneration, event)
    }

    func emit(event: VideoCaptureRuntimeEvent, generation: UInt64) async {
        await handler?(generation, event)
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
    func stopNowCount() -> Int { fullStops }

    func holdNextStart() { holdStart = true }

    func releaseHeldStart() {
        heldStartContinuation?.resume()
        heldStartContinuation = nil
    }

    func holdNextStopNow() { holdStopNow = true }

    func releaseHeldStopNow() {
        heldStopNowContinuation?.resume()
        heldStopNowContinuation = nil
    }

    func waitForStartCount(_ expected: Int) async {
        guard starts < expected else { return }
        await withCheckedContinuation { continuation in
            startObservers.append((expected, continuation))
        }
    }

    func waitForStopNowCount(_ expected: Int) async {
        guard fullStops < expected else { return }
        await withCheckedContinuation { continuation in
            stopNowObservers.append((expected, continuation))
        }
    }

    private func resumeObservers() {
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

    private func resumeStopNowObservers() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (expected, continuation) in stopNowObservers {
            if fullStops >= expected {
                continuation.resume()
            } else {
                remaining.append((expected, continuation))
            }
        }
        stopNowObservers = remaining
    }
}

private actor VideoPermissionProviderSpy: MediaPermissionProviding {
    private var statuses: [MediaPermissionKind: MediaAuthorizationStatus]
    private let requestResults: [MediaPermissionKind: MediaAuthorizationStatus]
    private var statusKinds: [MediaPermissionKind] = []
    private var requestKinds: [MediaPermissionKind] = []

    init(
        statuses: [MediaPermissionKind: MediaAuthorizationStatus],
        requestResults: [MediaPermissionKind: MediaAuthorizationStatus]
    ) {
        self.statuses = statuses
        self.requestResults = requestResults
    }

    func authorizationStatus(for kind: MediaPermissionKind) -> MediaAuthorizationStatus {
        statusKinds.append(kind)
        return statuses[kind] ?? .denied
    }

    func requestAuthorization(for kind: MediaPermissionKind) -> MediaAuthorizationStatus {
        requestKinds.append(kind)
        return requestResults[kind] ?? .denied
    }

    func statusCalls() -> [MediaPermissionKind] { statusKinds }
    func requestCalls() -> [MediaPermissionKind] { requestKinds }

    func setStatus(_ status: MediaAuthorizationStatus, for kind: MediaPermissionKind) {
        statuses[kind] = status
    }
}

private struct VideoPolicy: MediaRuntimePolicyProviding {
    let disabled: Bool
    func mediaDisabled() -> Bool { disabled }
}
