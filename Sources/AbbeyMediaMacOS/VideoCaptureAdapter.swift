@preconcurrency import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

public enum VideoCaptureSourceKind: String, CaseIterable, Sendable {
    case camera
    case display
    case window
}

public struct VideoCaptureSourceMetadata: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: VideoCaptureSourceKind
    public let title: String
    public let detail: String?

    public init(id: UUID, kind: VideoCaptureSourceKind, title: String, detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

enum SystemVideoCaptureSourceHandle: @unchecked Sendable {
    case camera(uniqueID: String)
    case display(SCDisplay)
    case window(SCWindow)

    /// Process-local reconciliation key. These platform identifiers never cross the module's
    /// public metadata boundary and are never persisted or included in diagnostics.
    var identity: SystemVideoCaptureSourceIdentity {
        switch self {
        case let .camera(uniqueID): .camera(uniqueID)
        case let .display(display): .display(display.displayID)
        case let .window(window): .window(window.windowID)
        }
    }
}

enum SystemVideoCaptureSourceIdentity: Hashable, Sendable {
    case camera(String)
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

/// Public source identity is deliberately ephemeral. Platform identifiers remain process-memory-only
/// and are excluded from descriptions, mirrors, status snapshots, and all persistence surfaces.
public struct VideoCaptureSourceSnapshot: Identifiable, Equatable, @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let id: UUID
    public let kind: VideoCaptureSourceKind
    public let title: String
    public let detail: String?
    let systemHandle: SystemVideoCaptureSourceHandle?

    public init(
        id: UUID = UUID(),
        kind: VideoCaptureSourceKind,
        title: String,
        detail: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        systemHandle = nil
    }

    init(
        id: UUID = UUID(),
        kind: VideoCaptureSourceKind,
        title: String,
        detail: String? = nil,
        systemHandle: SystemVideoCaptureSourceHandle
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.systemHandle = systemHandle
    }

    public var metadata: VideoCaptureSourceMetadata {
        VideoCaptureSourceMetadata(id: id, kind: kind, title: title, detail: detail)
    }

    var systemIdentity: SystemVideoCaptureSourceIdentity? {
        systemHandle?.identity
    }

    func replacingPublicID(_ id: UUID) -> VideoCaptureSourceSnapshot {
        guard let systemHandle else {
            return VideoCaptureSourceSnapshot(id: id, kind: kind, title: title, detail: detail)
        }
        return VideoCaptureSourceSnapshot(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            systemHandle: systemHandle
        )
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metadata == rhs.metadata
    }

    public var description: String {
        "VideoCaptureSourceSnapshot(id: \(id), kind: \(kind.rawValue), title: \(title))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "id": id.uuidString,
            "kind": kind.rawValue,
            "title": title,
            "detail": detail ?? "none"
        ])
    }
}

public protocol VideoCaptureSourceProviding: Sendable {
    func sourceSnapshots(
        includeCameras: Bool,
        includeScreens: Bool
    ) async throws -> [VideoCaptureSourceSnapshot]
}

public struct OwnedVideoFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: OSType
    public let presentationTimeNanoseconds: UInt64
    public let bytes: Data

    public init(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        presentationTimeNanoseconds: UInt64,
        bytes: Data
    ) throws {
        guard width > 0, height > 0, bytesPerRow >= width * 4 else {
            throw VideoCaptureError.invalidFrameGeometry
        }
        let (minimumByteCount, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, bytes.count >= minimumByteCount else {
            throw VideoCaptureError.invalidFrameByteCount
        }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.bytes = bytes
    }
}

public enum VideoCaptureRuntimeDelivery: Sendable {
    case frame(OwnedVideoFrame)
    case droppedSourceFrames(Int)
}

public enum VideoCaptureRuntimeEvent: Equatable, Sendable {
    case sourceRemoved(UUID)
    case interrupted
    case screenLocked
    case systemSuspended
    case configurationChanged
}

public protocol VideoCaptureRuntime: Sendable {
    func installEventHandler(
        _ handler: @escaping @Sendable (UInt64, VideoCaptureRuntimeEvent) async -> Void
    ) async
    func startCapture(
        generation: UInt64,
        source: VideoCaptureSourceSnapshot,
        deliver: @escaping @Sendable (UInt64, VideoCaptureRuntimeDelivery) async -> Void
    ) async throws
    func stopCapture() async
    func stopNow() async
}

public enum VideoCaptureState: Equatable, Sendable {
    case stopped
    case starting
    case capturing
    case interrupted
    case sourceUnavailable
    case failed(String)
}

public struct VideoCaptureStatusSnapshot: Equatable, Sendable {
    public let state: VideoCaptureState
    public let selectedSource: VideoCaptureSourceMetadata?
    public let droppedSourceFrames: Int
    public let droppedConsumerFrames: Int
    public let generation: UInt64

    public init(
        state: VideoCaptureState,
        selectedSource: VideoCaptureSourceMetadata?,
        droppedSourceFrames: Int,
        droppedConsumerFrames: Int,
        generation: UInt64
    ) {
        self.state = state
        self.selectedSource = selectedSource
        self.droppedSourceFrames = droppedSourceFrames
        self.droppedConsumerFrames = droppedConsumerFrames
        self.generation = generation
    }
}

/// Ordered, process-local capture output. Every frame carries the generation that
/// produced it, and lifecycle state changes share the same bounded channel so a
/// preview consumer can invalidate pixels without polling or retaining platform IDs.
public enum VideoCaptureEvent: Equatable, Sendable {
    case frame(generation: UInt64, frame: OwnedVideoFrame)
    case status(VideoCaptureStatusSnapshot)
}

public struct VideoCaptureAdapterConfiguration: Equatable, Sendable {
    public let maximumPendingSourceFrames: Int
    public let maximumCapturedFrames: Int

    public init(maximumPendingSourceFrames: Int = 4, maximumCapturedFrames: Int = 4) {
        self.maximumPendingSourceFrames = max(1, maximumPendingSourceFrames)
        self.maximumCapturedFrames = max(1, maximumCapturedFrames)
    }
}

public enum VideoCaptureError: Error, Equatable, Sendable {
    case disabledByEnvironment
    case permissionRequired(MediaPermissionKind, MediaAuthorizationStatus)
    case sourceRequired
    case unknownSource
    case sourceRefreshRequiresStoppedCapture
    case sourceSelectionRequiresStoppedCapture
    case unsupportedSource
    case captureAlreadyInstalled
    case invalidFrameGeometry
    case invalidFrameByteCount
    case pixelBufferUnavailable
    case runtimeFailure(String)
}

/// Local macOS capture boundary only. This type provides no Discord signaling, codec, RTP,
/// congestion control, DAVE protection, camera transmission, or Go Live implementation.
public actor VideoCaptureAdapter {
    private struct StartOperation: Sendable {
        let generation: UInt64
        let task: Task<UInt64, any Error>
    }

    private let sourceProvider: any VideoCaptureSourceProviding
    private let runtime: any VideoCaptureRuntime
    private let permissions: MediaPermissionController
    private let policy: any MediaRuntimePolicyProviding
    private let eventContinuation: AsyncStream<VideoCaptureEvent>.Continuation

    public nonisolated let captureEvents: AsyncStream<VideoCaptureEvent>

    private var sources: [VideoCaptureSourceSnapshot] = []
    private var selectedSource: VideoCaptureSourceSnapshot?
    private var state: VideoCaptureState = .stopped
    private var generation: UInt64 = 0
    private var startOperation: StartOperation?
    private var teardownGeneration: UInt64?
    private var eventsInstalled = false
    private var sourceDropCount = 0
    private var consumerDropCount = 0

    public init(
        sourceProvider: any VideoCaptureSourceProviding,
        runtime: any VideoCaptureRuntime,
        permissions: MediaPermissionController,
        policy: any MediaRuntimePolicyProviding,
        configuration: VideoCaptureAdapterConfiguration = .init()
    ) {
        self.sourceProvider = sourceProvider
        self.runtime = runtime
        self.permissions = permissions
        self.policy = policy
        let eventPair = AsyncStream<VideoCaptureEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(configuration.maximumCapturedFrames)
        )
        captureEvents = eventPair.stream
        eventContinuation = eventPair.continuation
    }

    public init(configuration: VideoCaptureAdapterConfiguration = .init()) {
        let policy = ProcessMediaRuntimePolicy()
        self.init(
            sourceProvider: SystemVideoCaptureSourceProvider(policy: policy),
            runtime: SystemVideoCaptureRuntime(
                policy: policy,
                maximumPendingSourceFrames: configuration.maximumPendingSourceFrames
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
        eventContinuation.finish()
    }

    public func authorizationStatus(for kind: VideoCaptureSourceKind) async -> MediaAuthorizationStatus {
        await permissions.authorizationStatus(for: permissionKind(for: kind))
    }

    public func requestCameraAuthorization() async throws -> MediaAuthorizationStatus {
        try requireEnabled()
        return try await permissions.requestAuthorization(for: .camera)
    }

    public func requestScreenAuthorization() async throws -> MediaAuthorizationStatus {
        try requireEnabled()
        return try await permissions.requestAuthorization(for: .screen)
    }

    /// Discovers only source classes already authorized by TCC. It never prompts.
    @discardableResult
    public func refreshSources() async throws -> [VideoCaptureSourceSnapshot] {
        try requireEnabled()
        guard state == .stopped else {
            throw VideoCaptureError.sourceRefreshRequiresStoppedCapture
        }
        let cameraAuthorized = await permissions.authorizationStatus(for: .camera) == .authorized
        let screenAuthorized = await permissions.authorizationStatus(for: .screen) == .authorized
        guard cameraAuthorized || screenAuthorized else {
            sources = []
            selectedSource = nil
            return []
        }

        let refreshed = try await sourceProvider.sourceSnapshots(
            includeCameras: cameraAuthorized,
            includeScreens: screenAuthorized
        )
        let priorSources = sources
        let selectedID = selectedSource?.id
        sources = refreshed.map { refreshedSource in
            guard let identity = refreshedSource.systemIdentity,
                  let prior = priorSources.first(where: { $0.systemIdentity == identity })
            else { return refreshedSource }
            return refreshedSource.replacingPublicID(prior.id)
        }
        selectedSource = selectedID.flatMap { selectedID in
            sources.first(where: { $0.id == selectedID })
        }
        return sources
    }

    public func currentSources() -> [VideoCaptureSourceSnapshot] { sources }

    public func selectSource(id: UUID?) throws {
        guard state == .stopped else {
            throw VideoCaptureError.sourceSelectionRequiresStoppedCapture
        }
        guard let id else {
            selectedSource = nil
            return
        }
        guard let source = sources.first(where: { $0.id == id }) else {
            throw VideoCaptureError.unknownSource
        }
        selectedSource = source
    }

    @discardableResult
    public func startCapture() async throws -> UInt64 {
        if state == .capturing { return generation }
        if let startOperation { return try await startOperation.task.value }
        guard teardownGeneration == nil else { throw CancellationError() }
        try requireEnabled()
        guard let selectedSource else { throw VideoCaptureError.sourceRequired }

        generation &+= 1
        let startingGeneration = generation
        state = .starting
        publishStatus()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performStart(
                generation: startingGeneration,
                source: selectedSource
            )
        }
        startOperation = StartOperation(generation: startingGeneration, task: task)
        do {
            let result = try await task.value
            clearStart(generation: startingGeneration)
            return result
        } catch {
            clearStart(generation: startingGeneration)
            throw error
        }
    }

    public func stopCapture() async {
        await stop(kill: false)
    }

    /// Immediate operator kill switch. It never schedules or permits an automatic restart.
    public func killSwitch() async {
        await stop(kill: true)
    }

    public func statusSnapshot() -> VideoCaptureStatusSnapshot {
        VideoCaptureStatusSnapshot(
            state: state,
            selectedSource: selectedSource?.metadata,
            droppedSourceFrames: sourceDropCount,
            droppedConsumerFrames: consumerDropCount,
            generation: generation
        )
    }

    private func performStart(
        generation startingGeneration: UInt64,
        source: VideoCaptureSourceSnapshot
    ) async throws -> UInt64 {
        do {
            try Task.checkCancellation()
            let kind = permissionKind(for: source.kind)
            let authorization = await permissions.authorizationStatus(for: kind)
            guard authorization == .authorized else {
                throw VideoCaptureError.permissionRequired(kind, authorization)
            }
            try Task.checkCancellation()
            await installEventsIfNeeded()
            try Task.checkCancellation()
            try await runtime.startCapture(
                generation: startingGeneration,
                source: source
            ) { [weak self] callbackGeneration, delivery in
                await self?.receive(delivery, generation: callbackGeneration)
            }
            try Task.checkCancellation()
            guard generation == startingGeneration, state == .starting else {
                throw CancellationError()
            }
            state = .capturing
            publishStatus()
            return startingGeneration
        } catch {
            await runtime.stopCapture()
            if generation == startingGeneration, state == .starting {
                generation &+= 1
                state = .failed(Self.describe(error))
                publishStatus()
            }
            throw error
        }
    }

    private func stop(kill: Bool) async {
        let pendingStart = startOperation
        pendingStart?.task.cancel()
        generation &+= 1
        let stoppingGeneration = generation
        teardownGeneration = stoppingGeneration
        if kill {
            await runtime.stopNow()
        } else {
            await runtime.stopCapture()
        }
        if let pendingStart {
            _ = try? await pendingStart.task.value
            clearStart(generation: pendingStart.generation)
        }
        guard teardownGeneration == stoppingGeneration else { return }
        teardownGeneration = nil
        state = .stopped
        publishStatus()
    }

    private func installEventsIfNeeded() async {
        guard !eventsInstalled else { return }
        eventsInstalled = true
        await runtime.installEventHandler { [weak self] callbackGeneration, event in
            await self?.receive(event: event, generation: callbackGeneration)
        }
    }

    private func receive(
        _ delivery: VideoCaptureRuntimeDelivery,
        generation callbackGeneration: UInt64
    ) {
        guard callbackGeneration == generation,
              state == .starting || state == .capturing
        else { return }
        switch delivery {
        case let .frame(frame):
            yieldEvent(.frame(generation: callbackGeneration, frame: frame))
        case let .droppedSourceFrames(count):
            if count > 0 { sourceDropCount += count }
        }
    }

    private func receive(
        event: VideoCaptureRuntimeEvent,
        generation callbackGeneration: UInt64
    ) async {
        guard callbackGeneration == generation,
              state == .starting || state == .capturing
        else { return }
        switch event {
        case let .sourceRemoved(sourceID):
            guard selectedSource?.id == sourceID else { return }
            state = .sourceUnavailable
        case .interrupted, .screenLocked, .systemSuspended:
            state = .interrupted
        case .configurationChanged:
            state = .interrupted
        }
        generation &+= 1
        let eventGeneration = generation
        teardownGeneration = eventGeneration
        startOperation?.task.cancel()
        // Publish invalidation before awaiting runtime teardown. A blocked framework
        // stop must never leave the last preview pixels visible after lock/suspend.
        publishStatus()
        await runtime.stopNow()
        if teardownGeneration == eventGeneration {
            teardownGeneration = nil
        }
    }

    private func clearStart(generation completedGeneration: UInt64) {
        guard startOperation?.generation == completedGeneration else { return }
        startOperation = nil
    }

    private func publishStatus() {
        yieldEvent(.status(statusSnapshot()))
    }

    private func yieldEvent(_ event: VideoCaptureEvent) {
        switch eventContinuation.yield(event) {
        case .enqueued, .terminated:
            break
        case let .dropped(droppedEvent):
            if case .frame = droppedEvent {
                consumerDropCount += 1
            }
        @unknown default:
            if case .frame = event {
                consumerDropCount += 1
            }
        }
    }

    private func requireEnabled() throws {
        guard !policy.mediaDisabled() else {
            throw VideoCaptureError.disabledByEnvironment
        }
    }

    private func permissionKind(for sourceKind: VideoCaptureSourceKind) -> MediaPermissionKind {
        sourceKind == .camera ? .camera : .screen
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as VideoCaptureError:
            String(describing: error)
        default:
            "Video capture runtime failed"
        }
    }
}

public struct SystemVideoCaptureSourceProvider: VideoCaptureSourceProviding {
    private let policy: any MediaRuntimePolicyProviding

    public init(policy: any MediaRuntimePolicyProviding = ProcessMediaRuntimePolicy()) {
        self.policy = policy
    }

    public func sourceSnapshots(
        includeCameras: Bool,
        includeScreens: Bool
    ) async throws -> [VideoCaptureSourceSnapshot] {
        guard !policy.mediaDisabled() else { throw VideoCaptureError.disabledByEnvironment }
        let permissionProvider = SystemMediaPermissionProvider()
        let camerasAllowed: Bool
        if includeCameras {
            camerasAllowed = await permissionProvider.authorizationStatus(for: .camera) == .authorized
        } else {
            camerasAllowed = false
        }
        let screensAllowed: Bool
        if includeScreens {
            screensAllowed = await permissionProvider.authorizationStatus(for: .screen) == .authorized
        } else {
            screensAllowed = false
        }
        var result: [VideoCaptureSourceSnapshot] = []

        if camerasAllowed {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video,
                position: .unspecified
            )
            result.append(contentsOf: session.devices.map { device in
                VideoCaptureSourceSnapshot(
                    kind: .camera,
                    title: device.localizedName,
                    detail: "Camera",
                    systemHandle: .camera(uniqueID: device.uniqueID)
                )
            })
        }

        if screensAllowed {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            for (index, display) in content.displays.enumerated() {
                result.append(
                    VideoCaptureSourceSnapshot(
                        kind: .display,
                        title: display.displayID == CGMainDisplayID() ? "Main Display" : "Display \(index + 1)",
                        detail: "\(display.width) × \(display.height)",
                        systemHandle: .display(display)
                    )
                )
            }
            result.append(contentsOf: content.windows.compactMap { window in
                guard let title = window.title, !title.isEmpty else { return nil }
                return VideoCaptureSourceSnapshot(
                    kind: .window,
                    title: title,
                    detail: window.owningApplication?.applicationName,
                    systemHandle: .window(window)
                )
            })
        }

        return result.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

struct PixelBufferSample: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}

/// A thread-safe, count-bounded handoff. Framework buffers are retained only until the single drain
/// task deep-copies them into `OwnedVideoFrame`; no callback creates an unstructured task.
final class BoundedVideoFrameIngress: @unchecked Sendable {
    let frames: AsyncStream<PixelBufferSample>
    private let continuation: AsyncStream<PixelBufferSample>.Continuation
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0

    init(capacity: Int) {
        let pair = AsyncStream<PixelBufferSample>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, capacity))
        )
        frames = pair.stream
        continuation = pair.continuation
    }

    func enqueue(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let sample = PixelBufferSample(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        switch continuation.yield(sample) {
        case .enqueued:
            lock.lock()
            pending += 1
            lock.unlock()
        case .dropped:
            lock.lock()
            dropped += 1
            lock.unlock()
        case .terminated:
            break
        @unknown default:
            lock.lock()
            dropped += 1
            lock.unlock()
        }
    }

    func didConsume() {
        lock.lock()
        pending = max(0, pending - 1)
        lock.unlock()
    }

    func takeDroppedCount() -> Int {
        lock.lock()
        let count = dropped
        dropped = 0
        lock.unlock()
        return count
    }

    var pendingFrameCount: Int {
        lock.lock()
        let count = pending
        lock.unlock()
        return count
    }

    func finish() { continuation.finish() }
}

actor SystemVideoCaptureRuntime: VideoCaptureRuntime {
    private let policy: any MediaRuntimePolicyProviding
    private let maximumPendingSourceFrames: Int
    private var eventHandler: (@Sendable (UInt64, VideoCaptureRuntimeEvent) async -> Void)?
    private var eventTasks: [Task<Void, Never>] = []
    private var ingress: BoundedVideoFrameIngress?
    private var drainTask: Task<Void, Never>?
    private var cameraSession: AVCaptureSession?
    private var cameraOutput: AVCaptureVideoDataOutput?
    private var cameraDelegate: CameraCaptureOutputDelegate?
    private var screenStream: SCStream?
    private var screenDelegate: ScreenCaptureOutputDelegate?
    private var currentSourceID: UUID?
    private var currentGeneration: UInt64?

    init(policy: any MediaRuntimePolicyProviding, maximumPendingSourceFrames: Int) {
        self.policy = policy
        self.maximumPendingSourceFrames = max(1, maximumPendingSourceFrames)
    }

    deinit {
        ingress?.finish()
        drainTask?.cancel()
        eventTasks.forEach { $0.cancel() }
        cameraSession?.stopRunning()
    }

    func installEventHandler(
        _ handler: @escaping @Sendable (UInt64, VideoCaptureRuntimeEvent) async -> Void
    ) {
        eventHandler = handler
        guard eventTasks.isEmpty else { return }

        eventTasks = [
            Task { [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(
                    named: NSWorkspace.sessionDidResignActiveNotification
                ) {
                    guard !Task.isCancelled else { return }
                    await self?.emitForCurrentCapture(.screenLocked)
                }
            },
            Task { [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(
                    named: NSWorkspace.willSleepNotification
                ) {
                    guard !Task.isCancelled else { return }
                    await self?.emitForCurrentCapture(.systemSuspended)
                }
            },
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: AVCaptureDevice.wasDisconnectedNotification
                ) {
                    guard !Task.isCancelled else { return }
                    guard let device = notification.object as? AVCaptureDevice else { continue }
                    await self?.cameraDisconnected(uniqueID: device.uniqueID)
                }
            },
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: AVCaptureSession.wasInterruptedNotification
                ) {
                    guard !Task.isCancelled else { return }
                    guard let session = notification.object as? AVCaptureSession else { continue }
                    await self?.cameraSessionEvent(
                        sessionIdentity: ObjectIdentifier(session),
                        event: .interrupted
                    )
                }
            },
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(
                    named: AVCaptureSession.runtimeErrorNotification
                ) {
                    guard !Task.isCancelled else { return }
                    guard let session = notification.object as? AVCaptureSession else { continue }
                    await self?.cameraSessionEvent(
                        sessionIdentity: ObjectIdentifier(session),
                        event: .configurationChanged
                    )
                }
            }
        ]
    }

    func startCapture(
        generation: UInt64,
        source: VideoCaptureSourceSnapshot,
        deliver: @escaping @Sendable (UInt64, VideoCaptureRuntimeDelivery) async -> Void
    ) async throws {
        guard !policy.mediaDisabled() else { throw VideoCaptureError.disabledByEnvironment }
        guard ingress == nil, cameraSession == nil, screenStream == nil else {
            throw VideoCaptureError.captureAlreadyInstalled
        }
        guard let handle = source.systemHandle else { throw VideoCaptureError.unsupportedSource }

        let ingress = BoundedVideoFrameIngress(capacity: maximumPendingSourceFrames)
        self.ingress = ingress
        currentSourceID = source.id
        currentGeneration = generation
        let drainTask = Task { [weak self, ingress] in
            guard let self else { return }
            await self.drain(ingress, generation: generation, deliver: deliver)
        }
        self.drainTask = drainTask

        do {
            switch handle {
            case let .camera(uniqueID):
                try startCamera(uniqueID: uniqueID, ingress: ingress)
            case let .display(display):
                try await startScreen(
                    filter: SCContentFilter(display: display, excludingWindows: []),
                    width: display.width,
                    height: display.height,
                    ingress: ingress,
                    sourceID: source.id,
                    generation: generation
                )
            case let .window(window):
                try await startScreen(
                    filter: SCContentFilter(desktopIndependentWindow: window),
                    width: Int(window.frame.width),
                    height: Int(window.frame.height),
                    ingress: ingress,
                    sourceID: source.id,
                    generation: generation
                )
            }
        } catch {
            await stopCapture()
            throw error
        }
    }

    func stopCapture() async {
        let oldIngress = ingress
        let oldDrain = drainTask
        currentGeneration = nil
        ingress = nil
        drainTask = nil
        oldIngress?.finish()
        oldDrain?.cancel()

        if let cameraSession {
            cameraSession.stopRunning()
            if let cameraOutput {
                cameraOutput.setSampleBufferDelegate(nil, queue: nil)
                cameraSession.removeOutput(cameraOutput)
            }
        }
        cameraSession = nil
        cameraOutput = nil
        cameraDelegate = nil

        if let screenStream {
            try? await screenStream.stopCapture()
        }
        screenStream = nil
        screenDelegate = nil
        currentSourceID = nil

        if let oldDrain { await oldDrain.value }
    }

    func stopNow() async {
        await stopCapture()
    }

    private func startCamera(uniqueID: String, ingress: BoundedVideoFrameIngress) throws {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else {
            throw VideoCaptureError.unsupportedSource
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let delegate = CameraCaptureOutputDelegate(ingress: ingress)
        output.setSampleBufferDelegate(
            delegate,
            queue: DispatchQueue(label: "AbbeyBot.Video.Camera", qos: .userInitiated)
        )

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw VideoCaptureError.runtimeFailure("The selected camera cannot be configured")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        cameraSession = session
        cameraOutput = output
        cameraDelegate = delegate
        session.startRunning()
    }

    private func startScreen(
        filter: SCContentFilter,
        width: Int,
        height: Int,
        ingress: BoundedVideoFrameIngress,
        sourceID: UUID,
        generation: UInt64
    ) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, width)
        configuration.height = max(1, height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = min(8, max(2, maximumPendingSourceFrames))
        configuration.capturesAudio = false
        configuration.showsCursor = true

        let delegate = ScreenCaptureOutputDelegate(
            ingress: ingress,
            generation: generation
        ) { [weak self] callbackGeneration, lifecycle in
            Task { [weak self] in
                let event: VideoCaptureRuntimeEvent = switch lifecycle {
                case .suspended: .interrupted
                case .stopped: .sourceRemoved(sourceID)
                }
                await self?.emit(event, generation: callbackGeneration)
            }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addStreamOutput(
            delegate,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "AbbeyBot.Video.Screen", qos: .userInitiated)
        )
        screenDelegate = delegate
        screenStream = stream
        try await stream.startCapture()
    }

    private func drain(
        _ ingress: BoundedVideoFrameIngress,
        generation: UInt64,
        deliver: @escaping @Sendable (UInt64, VideoCaptureRuntimeDelivery) async -> Void
    ) async {
        for await sample in ingress.frames {
            if Task.isCancelled { break }
            ingress.didConsume()
            let dropped = ingress.takeDroppedCount()
            if dropped > 0 {
                await deliver(generation, .droppedSourceFrames(dropped))
            }
            if let frame = Self.ownedFrame(from: sample) {
                await deliver(generation, .frame(frame))
            }
        }
    }

    static func ownedFrame(from sample: PixelBufferSample) -> OwnedVideoFrame? {
        let pixelBuffer = sample.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let byteCount = bytesPerRow * height
        let bytes = Data(bytes: baseAddress, count: byteCount)
        let seconds = CMTimeGetSeconds(sample.presentationTime)
        let timestamp = seconds.isFinite && seconds > 0
            ? UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
            : 0
        return try? OwnedVideoFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            presentationTimeNanoseconds: timestamp,
            bytes: bytes
        )
    }

    private func cameraDisconnected(uniqueID: String) async {
        guard case let .camera(activeID)? = currentHandle, activeID == uniqueID,
              let currentSourceID,
              let currentGeneration
        else { return }
        await emit(.sourceRemoved(currentSourceID), generation: currentGeneration)
    }

    private var currentHandle: SystemVideoCaptureSourceHandle? {
        guard let cameraSession,
              let deviceInput = cameraSession.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first
        else { return nil }
        return .camera(uniqueID: deviceInput.device.uniqueID)
    }

    private func cameraSessionEvent(
        sessionIdentity: ObjectIdentifier,
        event: VideoCaptureRuntimeEvent
    ) async {
        guard Self.isOwnedCameraSessionNotification(
            sessionIdentity: sessionIdentity,
            cameraSession: cameraSession
        ),
              let currentGeneration
        else { return }
        await emit(event, generation: currentGeneration)
    }

    static func isOwnedCameraSessionNotification(
        sessionIdentity: ObjectIdentifier,
        cameraSession: AVCaptureSession?
    ) -> Bool {
        guard let cameraSession else { return false }
        return sessionIdentity == ObjectIdentifier(cameraSession)
    }

    private func emitForCurrentCapture(_ event: VideoCaptureRuntimeEvent) async {
        guard let currentGeneration else { return }
        await emit(event, generation: currentGeneration)
    }

    private func emit(_ event: VideoCaptureRuntimeEvent, generation: UInt64) async {
        await eventHandler?(generation, event)
    }
}

private final class CameraCaptureOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let ingress: BoundedVideoFrameIngress

    init(ingress: BoundedVideoFrameIngress) {
        self.ingress = ingress
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        ingress.enqueue(
            pixelBuffer: pixelBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }
}

enum ScreenCaptureFrameLifecycle: Equatable, Sendable {
    case suspended
    case stopped
}

enum ScreenCaptureSampleDisposition: Equatable, Sendable {
    case frame
    case lifecycle(ScreenCaptureFrameLifecycle)
    case ignore
}

final class ScreenCaptureOutputDelegate: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    private let ingress: BoundedVideoFrameIngress
    private let generation: UInt64
    private let lifecycle: @Sendable (UInt64, ScreenCaptureFrameLifecycle) -> Void

    init(
        ingress: BoundedVideoFrameIngress,
        generation: UInt64,
        lifecycle: @escaping @Sendable (UInt64, ScreenCaptureFrameLifecycle) -> Void
    ) {
        self.ingress = ingress
        self.generation = generation
        self.lifecycle = lifecycle
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        handle(
            status: Self.frameStatus(from: sampleBuffer),
            pixelBuffer: CMSampleBufferGetImageBuffer(sampleBuffer),
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lifecycle(generation, .stopped)
    }

    func handle(
        status: SCFrameStatus?,
        pixelBuffer: CVPixelBuffer?,
        presentationTime: CMTime
    ) {
        switch Self.disposition(for: status) {
        case .frame:
            guard let pixelBuffer else { return }
            ingress.enqueue(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        case let .lifecycle(event):
            lifecycle(generation, event)
        case .ignore:
            return
        }
    }

    static func disposition(for status: SCFrameStatus?) -> ScreenCaptureSampleDisposition {
        switch status {
        case .complete: .frame
        case .suspended: .lifecycle(.suspended)
        case .stopped: .lifecycle(.stopped)
        case .idle, .blank, .started, .none: .ignore
        @unknown default: .ignore
        }
    }

    private static func frameStatus(from sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? NSNumber
        else { return nil }
        return SCFrameStatus(rawValue: rawStatus.intValue)
    }
}
