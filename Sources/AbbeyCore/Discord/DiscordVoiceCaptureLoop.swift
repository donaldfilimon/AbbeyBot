import Foundation

/// Send-side view of an installed voice media plane.
///
/// The production implementation is `DiscordVoiceNativeMediaPlane.sendAudioFrame(pcm:)`,
/// which already fails closed unless a negotiated generation with an attested
/// DAVE session is installed. The capture loop never sees keys, SSRCs,
/// transport modes, or wire packets through this boundary — only the throwing
/// send call.
public protocol DiscordVoiceAudioFrameSender: Sendable {
    /// Sends one exact 20 ms, 48 kHz stereo interleaved PCM frame through the
    /// full protected send path. Implementations must throw rather than fall
    /// back to weaker protection when the protected path is unavailable.
    func sendAudioFrame(pcm: [Int16]) async throws
}

/// Platform capture boundary for the voice capture loop.
///
/// `startCapture()` performs the platform's own permission preflight and
/// engine start, then returns a stream of exact 20 ms frames
/// (`DiscordVoiceCaptureLoop.interleavedSampleCount` interleaved `Int16`
/// samples at 48 kHz stereo). The stream finishing while the loop is running
/// means capture ended outside the operator's control (device removal,
/// interruption, configuration change) and the loop fails closed.
/// `stopCapture()` must be idempotent.
public protocol DiscordVoiceCaptureSource: Sendable {
    func startCapture() async throws -> AsyncStream<[Int16]>
    func stopCapture() async
}

public enum DiscordVoiceCaptureLoopPhase: String, Equatable, Sendable {
    case idle
    case capturing
    case stopped
    case failed
}

/// Redacted by construction: no case carries device names, permission
/// details, or the underlying platform error.
public enum DiscordVoiceCaptureLoopError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyRunning
    case staleGeneration
    /// The capture source could not start (permission or device loss). The
    /// platform error is deliberately not carried.
    case captureUnavailable
    /// The loop was stopped or superseded while its start was suspended.
    case interrupted

    public var description: String {
        switch self {
        case .alreadyRunning: "Voice capture loop is already running"
        case .staleGeneration: "Voice capture loop start belongs to an obsolete generation"
        case .captureUnavailable: "Voice capture source is unavailable"
        case .interrupted: "Voice capture loop start was interrupted"
        }
    }
}

/// Control surface the voice controller drives, kept narrow so tests can
/// substitute a deterministic fake without a real source or media plane.
public protocol DiscordVoiceCaptureLoopControlling: Sendable {
    /// Starts capture for the given controller generation. Equal-generation
    /// restarts are allowed (mute/unmute cycles reuse one established
    /// session); lower generations are rejected as stale.
    func start(generation: UInt64) async throws
    /// Ordered teardown: the capture source is stopped and the pump drained
    /// before this returns, so the owner may reset the media plane
    /// immediately afterwards.
    func stop() async
    /// Invoked once when the loop terminates on its own (send failure,
    /// malformed framing, or unexpected capture end) — never on `stop()`.
    func setTerminalHandler(_ handler: (@Sendable () async -> Void)?) async
}

/// Phase 6a capture composition: pumps exact 20 ms PCM frames from an
/// injected capture source into the protected `sendAudioFrame` path.
///
/// Fail-closed rules, in order of checking per frame: a superseded revision
/// stops silently (a deliberate `stop()` or replacement owns state), a
/// malformed frame terminates the loop without sending, and any sender error
/// terminates the loop — there is no retry, no buffering fallback, and no
/// path that could downgrade protection. No PCM, frame content, or device
/// detail is ever logged or exposed; diagnostics are counts and phases only.
public actor DiscordVoiceCaptureLoop: DiscordVoiceCaptureLoopControlling,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public struct Snapshot: Equatable, Sendable, CustomStringConvertible {
        public let phase: DiscordVoiceCaptureLoopPhase
        public let sentFrameCount: UInt64

        public var description: String {
            "DiscordVoiceCaptureLoop.Snapshot(phase: \(phase.rawValue), sentFrameCount: \(sentFrameCount))"
        }
    }

    /// 48 kHz * 20 ms * 2 channels.
    public static let interleavedSampleCount = 1_920

    private let source: any DiscordVoiceCaptureSource
    private let sender: any DiscordVoiceAudioFrameSender

    private var highestGeneration: UInt64 = 0
    private var revision: UInt64 = 0
    private var phase: DiscordVoiceCaptureLoopPhase = .idle
    private var pumpTask: Task<Void, Never>?
    private var sentFrameCount: UInt64 = 0
    private var terminalHandler: (@Sendable () async -> Void)?

    public init(
        source: any DiscordVoiceCaptureSource,
        sender: any DiscordVoiceAudioFrameSender
    ) {
        self.source = source
        self.sender = sender
    }

    public nonisolated var description: String { "DiscordVoiceCaptureLoop(<redacted>)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["capture": "<redacted>"], displayStyle: .class)
    }

    public func snapshot() -> Snapshot {
        Snapshot(phase: phase, sentFrameCount: sentFrameCount)
    }

    public func setTerminalHandler(_ handler: (@Sendable () async -> Void)?) {
        terminalHandler = handler
    }

    public func start(generation: UInt64) async throws {
        guard pumpTask == nil, phase != .capturing else {
            throw DiscordVoiceCaptureLoopError.alreadyRunning
        }
        // Unlike the media plane's one-shot key watermark, an equal generation
        // may restart: the operator's mute cycle stops and restarts capture
        // within one established session, and the loop holds no key material.
        // Lower (and zero) generations remain rejected as stale.
        guard generation > 0, generation >= highestGeneration else {
            throw DiscordVoiceCaptureLoopError.staleGeneration
        }
        highestGeneration = generation
        revision &+= 1
        let startRevision = revision
        phase = .capturing

        let frames: AsyncStream<[Int16]>
        do {
            frames = try await source.startCapture()
        } catch {
            if revision == startRevision {
                phase = .failed
            }
            throw DiscordVoiceCaptureLoopError.captureUnavailable
        }
        guard revision == startRevision, !Task.isCancelled else {
            await source.stopCapture()
            throw DiscordVoiceCaptureLoopError.interrupted
        }
        pumpTask = Task { await self.pump(frames, revision: startRevision) }
    }

    /// Ordered teardown: cancels the pump, stops the capture source, and
    /// drains the pump before returning. Callers reset the media plane only
    /// after this completes, so no frame can race a media reset.
    public func stop() async {
        revision &+= 1
        let task = pumpTask
        pumpTask = nil
        task?.cancel()
        await source.stopCapture()
        if let task { await task.value }
        if phase == .capturing {
            phase = .stopped
        }
    }

    private func pump(_ frames: AsyncStream<[Int16]>, revision startRevision: UInt64) async {
        for await pcm in frames {
            guard revision == startRevision, !Task.isCancelled else { return }
            guard pcm.count == Self.interleavedSampleCount else {
                await failCapture(revision: startRevision)
                return
            }
            do {
                try await sender.sendAudioFrame(pcm: pcm)
                // Counted the moment the send succeeds, not after the next
                // revision check: the frame really did reach the wire, and a
                // `stop()` landing in between must not un-count it. (That
                // window is real — the send path suspends on a tracked child
                // task — and made this counter flaky under teardown.)
                sentFrameCount &+= 1
            } catch {
                await failCapture(revision: startRevision)
                return
            }
            guard revision == startRevision else { return }
        }
        // The source finished the stream on its own: device removal,
        // interruption, or configuration change. A deliberate `stop()` bumps
        // the revision before finishing the stream, so an intact revision
        // here is an unexpected end — fail closed.
        if revision == startRevision {
            await failCapture(revision: startRevision)
        }
    }

    private func failCapture(revision startRevision: UInt64) async {
        guard revision == startRevision else { return }
        revision &+= 1
        phase = .failed
        pumpTask = nil
        await source.stopCapture()
        if let terminalHandler {
            // Detached so a handler that calls back into `stop()` cannot
            // deadlock against the pump task it is running on.
            Task { await terminalHandler() }
        }
    }
}
