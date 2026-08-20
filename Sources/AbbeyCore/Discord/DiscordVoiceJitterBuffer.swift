import Foundation

// MARK: - Injectable clock

/// Monotonic time source for the receive path.
///
/// Only *differences* between two `now()` readings are meaningful; the origin is
/// unspecified. Everything time-dependent in the receive path (idle-stream
/// eviction) reads through this seam so tests advance time explicitly instead of
/// sleeping. Determinism here is a requirement, not a convenience: an eviction
/// test that slept on a wall clock would be both slow and flaky.
public protocol DiscordVoiceReceiveClock: Sendable {
    func now() -> Duration
}

/// Production clock: a monotonic `ContinuousClock` rebased at construction so
/// readings are small durations rather than absolute instants.
public struct DiscordVoiceContinuousReceiveClock: DiscordVoiceReceiveClock {
    private let origin: ContinuousClock.Instant

    public init() {
        self.origin = ContinuousClock.now
    }

    public func now() -> Duration {
        ContinuousClock.now - origin
    }
}

// MARK: - Configuration

public enum DiscordVoiceJitterBufferError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidTargetDepth(Int)
    case invalidMaximumConcealedFrames(Int)
    case invalidIdleTimeout
    case invalidMaximumStreams(Int)
    case invalidMaximumMixLag(Int)

    public var description: String {
        switch self {
        case .invalidTargetDepth(let depth):
            "Jitter buffer target depth must be in 1...64; got \(depth)"
        case .invalidMaximumConcealedFrames(let count):
            "Jitter buffer maximum concealed frames must be in 1...64; got \(count)"
        case .invalidIdleTimeout:
            "Jitter buffer idle timeout must be greater than zero"
        case .invalidMaximumStreams(let count):
            "Jitter buffer maximum concurrent streams must be in 1...1024; got \(count)"
        case .invalidMaximumMixLag(let count):
            "Audio mix queue maximum lag must be in 1...64; got \(count)"
        }
    }
}

public struct DiscordVoiceJitterBufferConfiguration: Equatable, Sendable {
    /// ~4 packets of 20 ms audio ≈ 80 ms of reorder tolerance.
    public static let defaultTargetDepth = 4

    /// Packets held per stream before the oldest is released. A stream can hold
    /// at most `targetDepth + 1` packets at any instant, which is what bounds
    /// memory against a broken or hostile sender.
    public let targetDepth: Int

    /// Longest run of consecutive concealed frames before the release cursor
    /// resynchronizes to the oldest buffered packet. Without this, a sender that
    /// jumps far forward would force a concealment frame for every skipped
    /// sequence number.
    public let maximumConcealedFrames: Int

    /// A stream with no accepted packet for this long is evicted, so a busy
    /// guild does not accumulate per-speaker state forever.
    public let idleTimeout: Duration

    /// Hard cap on concurrent per-SSRC streams. The idle timeout alone does not
    /// bound memory: a sender spraying fresh SSRCs would create unbounded stream
    /// state before any timeout fires. Mirrors `DiscordVoiceRTPSourceMap`'s
    /// bounded-capacity precedent.
    public let maximumStreams: Int

    public init(
        targetDepth: Int = defaultTargetDepth,
        maximumConcealedFrames: Int = 4,
        idleTimeout: Duration = .seconds(5),
        maximumStreams: Int = 64
    ) throws {
        guard (1...64).contains(targetDepth) else {
            throw DiscordVoiceJitterBufferError.invalidTargetDepth(targetDepth)
        }
        guard (1...64).contains(maximumConcealedFrames) else {
            throw DiscordVoiceJitterBufferError.invalidMaximumConcealedFrames(maximumConcealedFrames)
        }
        guard idleTimeout > .zero else {
            throw DiscordVoiceJitterBufferError.invalidIdleTimeout
        }
        guard (1...1_024).contains(maximumStreams) else {
            throw DiscordVoiceJitterBufferError.invalidMaximumStreams(maximumStreams)
        }
        self.targetDepth = targetDepth
        self.maximumConcealedFrames = maximumConcealedFrames
        self.idleTimeout = idleTimeout
        self.maximumStreams = maximumStreams
    }
}

// MARK: - Per-stream reorder buffer

/// Why a packet was not admitted. Every case is a counted drop; none of them
/// terminates the receive loop.
public enum DiscordVoiceJitterBufferRejection: String, Equatable, Sendable {
    /// Already seen at this sequence number (replay or network duplicate).
    case duplicate
    /// Behind the replay window — too far in the past to judge.
    case tooOld
    /// A forward jump larger than the replay window tolerates.
    case tooFarAhead
    /// Inside the replay window but behind the release cursor: its slot has
    /// already been released or concealed, so playing it now would be
    /// out-of-order audio.
    case late
}

/// One unit of in-order output. The buffer never decodes: it reorders the
/// *protected* packets and hands them out in sequence order, so the decoder's
/// Opus state advances monotonically and `conceal` lands in the right slot.
public enum DiscordVoiceJitterBufferRelease: Equatable, Sendable {
    case packet(sequence: UInt16, bytes: [UInt8])
    case conceal(sequence: UInt16)
}

public struct DiscordVoiceJitterBufferOutcome: Equatable, Sendable {
    public let rejection: DiscordVoiceJitterBufferRejection?
    public let releases: [DiscordVoiceJitterBufferRelease]
    /// The release cursor skipped forward past an unfillable gap rather than
    /// concealing every missing sequence number.
    public let resynchronized: Bool

    public init(
        rejection: DiscordVoiceJitterBufferRejection? = nil,
        releases: [DiscordVoiceJitterBufferRelease] = [],
        resynchronized: Bool = false
    ) {
        self.rejection = rejection
        self.releases = releases
        self.resynchronized = resynchronized
    }
}

/// Bounded per-SSRC reorder buffer over RTP's wrapping 16-bit sequence space.
///
/// Duplicate/replay rejection reuses `DiscordVoiceRTPReplayWindow`, which
/// already does modular comparison and bounds forward jumps. The buffer adds the
/// release cursor on top: every comparison against it is modular too
/// (`sequence &- cursor >= 0x8000` means "behind"), because a naive `>` breaks at
/// the 65535 → 0 wrap and would silently drop a stream forever.
public struct DiscordVoiceStreamJitterBuffer: Sendable {
    public let configuration: DiscordVoiceJitterBufferConfiguration

    private var replayWindow: DiscordVoiceRTPReplayWindow
    private var pending: [UInt16: [UInt8]]
    private var releaseCursor: UInt16?

    public private(set) var lastActivity: Duration
    public private(set) var concealedFrameCount: UInt64 = 0
    public private(set) var rejectedPacketCount: UInt64 = 0

    public init(
        configuration: DiscordVoiceJitterBufferConfiguration,
        now: Duration
    ) throws {
        self.configuration = configuration
        self.replayWindow = try DiscordVoiceRTPReplayWindow()
        self.pending = [:]
        self.pending.reserveCapacity(configuration.targetDepth + 1)
        self.releaseCursor = nil
        self.lastActivity = now
    }

    public var pendingCount: Int { pending.count }

    /// Admits one protected packet and returns whatever became releasable.
    ///
    /// `lastActivity` advances only for accepted packets: a flood of duplicates
    /// must not keep a dead stream alive past its idle timeout.
    public mutating func insert(
        sequence: UInt16,
        packet: [UInt8],
        now: Duration
    ) -> DiscordVoiceJitterBufferOutcome {
        switch replayWindow.observe(sequence) {
        case .duplicate:
            rejectedPacketCount &+= 1
            return DiscordVoiceJitterBufferOutcome(rejection: .duplicate)
        case .tooOld:
            rejectedPacketCount &+= 1
            return DiscordVoiceJitterBufferOutcome(rejection: .tooOld)
        case .tooFarAhead:
            rejectedPacketCount &+= 1
            return DiscordVoiceJitterBufferOutcome(rejection: .tooFarAhead)
        case .acceptedFirst, .acceptedNewHighest, .acceptedReordered:
            break
        }

        if releaseCursor == nil {
            releaseCursor = sequence
        }
        guard let cursor = releaseCursor else {
            return DiscordVoiceJitterBufferOutcome()
        }
        // Modular "behind the cursor" test. The upper half of the sequence
        // space is the past; `<` on raw UInt16 would misjudge every packet
        // across the wrap.
        if sequence &- cursor >= 0x8000 {
            rejectedPacketCount &+= 1
            return DiscordVoiceJitterBufferOutcome(rejection: .late)
        }

        lastActivity = now
        pending[sequence] = packet
        return drainReleases()
    }

    private mutating func drainReleases() -> DiscordVoiceJitterBufferOutcome {
        var releases: [DiscordVoiceJitterBufferRelease] = []
        var resynchronized = false

        while pending.count > configuration.targetDepth, let cursor = releaseCursor {
            if let bytes = pending.removeValue(forKey: cursor) {
                releases.append(.packet(sequence: cursor, bytes: bytes))
                releaseCursor = cursor &+ 1
                continue
            }
            // The head of the stream is missing and the buffer is already over
            // depth, so the gap can no longer be filled by a late arrival.
            guard let lowest = lowestPendingSequence(after: cursor) else { break }
            let gap = lowest &- cursor
            if Int(gap) > configuration.maximumConcealedFrames {
                releaseCursor = lowest
                resynchronized = true
                continue
            }
            releases.append(.conceal(sequence: cursor))
            concealedFrameCount &+= 1
            releaseCursor = cursor &+ 1
        }

        return DiscordVoiceJitterBufferOutcome(
            rejection: nil,
            releases: releases,
            resynchronized: resynchronized
        )
    }

    /// The buffered sequence closest ahead of `cursor`, compared modularly.
    private func lowestPendingSequence(after cursor: UInt16) -> UInt16? {
        pending.keys.min { lhs, rhs in
            (lhs &- cursor) < (rhs &- cursor)
        }
    }
}

// MARK: - Mixing

public enum DiscordVoiceAudioMixer {
    /// Sums frames sample-wise with a **saturating** clipping guard.
    ///
    /// The accumulator is `Int32` and the result is clamped to `Int16`'s range.
    /// Wrapping addition (`&+`) here would turn two loud overlapping speakers
    /// into a full-scale sign flip — an audible artifact, and a correctness bug
    /// rather than a rough edge. Shorter frames contribute silence past their
    /// end, so a ragged input never truncates the mix.
    public static func mix(_ frames: [[Int16]]) -> [Int16] {
        guard let longest = frames.map(\.count).max(), longest > 0 else { return [] }
        if frames.count == 1 { return frames[0] }
        var mixed = [Int16](repeating: 0, count: longest)
        for index in 0..<longest {
            var accumulator: Int32 = 0
            for frame in frames where index < frame.count {
                accumulator += Int32(frame[index])
            }
            mixed[index] = Int16(
                clamping: accumulator
            )
        }
        return mixed
    }
}

/// Schedules decoded per-SSRC frames into single mixed frames for playback.
///
/// There is no portable playback clock in this layer, so frame alignment across
/// speakers is an explicit policy rather than a synchronization guarantee: a
/// mixed frame is emitted when every registered stream has a frame ready, or
/// when any stream has fallen `maximumLag` frames behind (which is what stops a
/// speaker who went silent from stalling everyone else's playback). Queue depth
/// is therefore bounded by `maximumLag`.
public struct DiscordVoiceAudioMixQueue: Sendable {
    public let maximumLag: Int

    private var queues: [UInt32: [[Int16]]] = [:]

    public init(maximumLag: Int = DiscordVoiceJitterBufferConfiguration.defaultTargetDepth) throws {
        guard (1...64).contains(maximumLag) else {
            throw DiscordVoiceJitterBufferError.invalidMaximumMixLag(maximumLag)
        }
        self.maximumLag = maximumLag
    }

    public var registeredStreamCount: Int { queues.count }

    public mutating func register(ssrc: UInt32) {
        if queues[ssrc] == nil { queues[ssrc] = [] }
    }

    /// Drops any frames still queued for `ssrc`. Called when a stream is
    /// evicted; the alternative — draining them alone — would play a burst of
    /// stale audio after the speaker already went away.
    public mutating func remove(ssrc: UInt32) {
        queues.removeValue(forKey: ssrc)
    }

    public mutating func removeAll() {
        queues.removeAll(keepingCapacity: false)
    }

    public mutating func append(_ pcm: [Int16], ssrc: UInt32) {
        queues[ssrc, default: []].append(pcm)
    }

    /// Emits every mixed frame that is ready under the policy above.
    public mutating func drainReadyFrames() -> [[Int16]] {
        var mixedFrames: [[Int16]] = []
        while shouldEmit {
            var ready: [[Int16]] = []
            for ssrc in queues.keys where !(queues[ssrc]?.isEmpty ?? true) {
                ready.append(queues[ssrc]!.removeFirst())
            }
            guard !ready.isEmpty else { break }
            mixedFrames.append(DiscordVoiceAudioMixer.mix(ready))
        }
        return mixedFrames
    }

    private var shouldEmit: Bool {
        guard !queues.isEmpty else { return false }
        guard queues.values.contains(where: { !$0.isEmpty }) else { return false }
        if queues.values.allSatisfy({ !$0.isEmpty }) { return true }
        return queues.values.contains { $0.count >= maximumLag }
    }
}
