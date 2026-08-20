import Foundation

// MARK: - Decryption boundary

/// One decoded 20 ms frame together with the SSRC the media plane attributes it
/// to. Carries PCM only — never keys, nonces, or wire bytes.
public struct DiscordVoiceDecodedAudio: Equatable, Sendable {
    public let ssrc: UInt32
    public let pcm: [Int16]

    public init(ssrc: UInt32, pcm: [Int16]) {
        self.ssrc = ssrc
        self.pcm = pcm
    }
}

/// Receive-side view of an installed voice media plane, mirroring
/// `DiscordVoiceAudioFrameSender` on the send side.
///
/// **The decryption boundary is load-bearing.** The production implementation
/// lives in the native media plane, which owns the keys and performs AEAD
/// `open` → DAVE `unprotect` → Opus `decode` in one step. The portable receive
/// loop never sees key material, transport modes, or plaintext packet bytes; it
/// only reorders *protected* packets and hands them across this seam in
/// sequence order.
///
/// Ordering is part of the contract: an Opus decoder is stateful, so packets
/// must arrive here in ascending sequence order per SSRC, and `concealAudioFrame`
/// must be called in the slot of the sequence number it stands in for.
///
/// Implementations must fail closed: a packet that cannot be authenticated,
/// unprotected, or decoded throws, and the thrown error must not carry key
/// material, SSRCs, or packet contents.
public protocol DiscordVoiceAudioFrameDecoder: Sendable {
    func decodeAudioFrame(packet: [UInt8]) async throws -> DiscordVoiceDecodedAudio
    /// One 20 ms packet-loss-concealment frame for a gap in `ssrc`'s stream.
    func concealAudioFrame(ssrc: UInt32) async throws -> [Int16]
}

/// Playback boundary for mixed frames. The production implementation is the
/// platform audio engine; the loop treats a playback failure the way the capture
/// loop treats a send failure — terminal, with no retry and no fallback.
public protocol DiscordVoicePlaybackSink: Sendable {
    func play(pcm: [Int16]) async throws
}

// MARK: - Loop surface

public enum DiscordVoiceReceiveLoopPhase: String, Equatable, Sendable {
    case idle
    case receiving
    case stopped
    case failed
}

/// Redacted by construction: no case carries packet bytes, SSRCs, endpoint
/// detail, or the underlying transport error.
public enum DiscordVoiceReceiveLoopError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyRunning
    case staleGeneration

    public var description: String {
        switch self {
        case .alreadyRunning: "Voice receive loop is already running"
        case .staleGeneration: "Voice receive loop start belongs to an obsolete generation"
        }
    }
}

/// Control surface the voice controller drives, kept narrow so tests can
/// substitute a deterministic fake without a real transport or media plane.
public protocol DiscordVoiceReceiveLoopControlling: Sendable {
    /// Starts receiving for the given controller generation. Lower (and zero)
    /// generations are rejected as stale.
    func start(generation: UInt64) async throws
    /// Ordered teardown: the pump is cancelled and drained before this returns,
    /// so the owner may reset the media plane immediately afterwards without a
    /// packet racing the reset.
    func stop() async
    /// Invoked once when the loop terminates on its own (terminal transport
    /// failure, malformed RTP framing, or a playback failure) — never on
    /// `stop()`.
    func setTerminalHandler(_ handler: (@Sendable () async -> Void)?) async
}

// MARK: - Receive loop

/// Portable receive composition: pumps protected datagrams from an injected
/// transport, routes them per SSRC through a bounded reorder buffer, drives
/// in-order decode and packet-loss concealment across the media-plane seam, and
/// plays the saturating mix of all active speakers.
///
/// Failure policy, deliberately split three ways:
///
/// * **Terminal** — a transport error, unparseable RTP *framing*, or a playback
///   failure ends the loop through the terminal handler. These mean the stream
///   itself is no longer trustworthy.
/// * **Counted drop, loop continues** — a well-formed packet this layer does not
///   decode (a video payload type, or an RTX/RTCP-shaped payload type the RTP
///   header validator rejects), a packet rejected by the reorder buffer
///   (duplicate, replay, too old, too far ahead, late), a stream beyond the
///   concurrency cap, or a packet that fails AEAD/DAVE/Opus at the media plane.
///   Discord's media socket carries video and RTX alongside audio, so treating
///   an unexpected payload type as terminal would kill receive on the first
///   video packet.
/// * **Silent stop** — a superseded revision. A deliberate `stop()` or a
///   replacement owns the state from that point on.
///
/// No PCM, packet bytes, SSRC, or device detail is ever logged or exposed;
/// diagnostics are counts and phases only.
public actor DiscordVoiceReceiveLoop: DiscordVoiceReceiveLoopControlling,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public struct Snapshot: Equatable, Sendable, CustomStringConvertible {
        public let phase: DiscordVoiceReceiveLoopPhase
        public let activeStreamCount: Int
        public let receivedPacketCount: UInt64
        public let ignoredPacketCount: UInt64
        public let rejectedPacketCount: UInt64
        public let droppedPacketCount: UInt64
        public let rejectedStreamCount: UInt64
        public let decodedFrameCount: UInt64
        public let concealedFrameCount: UInt64
        public let mixedFrameCount: UInt64
        public let evictedStreamCount: UInt64

        public var description: String {
            """
            DiscordVoiceReceiveLoop.Snapshot(phase: \(phase.rawValue), \
            activeStreams: \(activeStreamCount), received: \(receivedPacketCount), \
            ignored: \(ignoredPacketCount), rejected: \(rejectedPacketCount), \
            dropped: \(droppedPacketCount), rejectedStreams: \(rejectedStreamCount), \
            decoded: \(decodedFrameCount), concealed: \(concealedFrameCount), \
            mixed: \(mixedFrameCount), evicted: \(evictedStreamCount))
            """
        }
    }

    private let transport: any DiscordVoiceMediaDatagramTransport
    private let decoder: any DiscordVoiceAudioFrameDecoder
    private let sink: any DiscordVoicePlaybackSink
    private let codec: DiscordVoiceRTPCodec
    private let configuration: DiscordVoiceJitterBufferConfiguration
    private let clock: any DiscordVoiceReceiveClock

    private var streams: [UInt32: DiscordVoiceStreamJitterBuffer] = [:]
    private var mixQueue: DiscordVoiceAudioMixQueue

    private var highestGeneration: UInt64 = 0
    private var revision: UInt64 = 0
    private var phase: DiscordVoiceReceiveLoopPhase = .idle
    private var pumpTask: Task<Void, Never>?
    private var terminalHandler: (@Sendable () async -> Void)?

    private var receivedPacketCount: UInt64 = 0
    private var ignoredPacketCount: UInt64 = 0
    private var rejectedPacketCount: UInt64 = 0
    private var droppedPacketCount: UInt64 = 0
    private var rejectedStreamCount: UInt64 = 0
    private var decodedFrameCount: UInt64 = 0
    private var concealedFrameCount: UInt64 = 0
    private var mixedFrameCount: UInt64 = 0
    private var evictedStreamCount: UInt64 = 0

    public init(
        transport: any DiscordVoiceMediaDatagramTransport,
        decoder: any DiscordVoiceAudioFrameDecoder,
        sink: any DiscordVoicePlaybackSink,
        configuration: DiscordVoiceJitterBufferConfiguration? = nil,
        codec: DiscordVoiceRTPCodec? = nil,
        clock: any DiscordVoiceReceiveClock = DiscordVoiceContinuousReceiveClock()
    ) throws {
        let resolvedConfiguration = try configuration ?? DiscordVoiceJitterBufferConfiguration()
        self.transport = transport
        self.decoder = decoder
        self.sink = sink
        self.configuration = resolvedConfiguration
        self.codec = try codec ?? DiscordVoiceRTPCodec()
        self.clock = clock
        self.mixQueue = try DiscordVoiceAudioMixQueue(
            maximumLag: resolvedConfiguration.targetDepth
        )
    }

    public nonisolated var description: String { "DiscordVoiceReceiveLoop(<redacted>)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["receive": "<redacted>"], displayStyle: .class)
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            phase: phase,
            activeStreamCount: streams.count,
            receivedPacketCount: receivedPacketCount,
            ignoredPacketCount: ignoredPacketCount,
            rejectedPacketCount: rejectedPacketCount,
            droppedPacketCount: droppedPacketCount,
            rejectedStreamCount: rejectedStreamCount,
            decodedFrameCount: decodedFrameCount,
            concealedFrameCount: concealedFrameCount,
            mixedFrameCount: mixedFrameCount,
            evictedStreamCount: evictedStreamCount
        )
    }

    public func setTerminalHandler(_ handler: (@Sendable () async -> Void)?) {
        terminalHandler = handler
    }

    public func start(generation: UInt64) async throws {
        guard pumpTask == nil, phase != .receiving else {
            throw DiscordVoiceReceiveLoopError.alreadyRunning
        }
        guard generation > 0, generation >= highestGeneration else {
            throw DiscordVoiceReceiveLoopError.staleGeneration
        }
        highestGeneration = generation
        revision &+= 1
        let startRevision = revision
        phase = .receiving
        streams.removeAll()
        mixQueue.removeAll()
        pumpTask = Task { await self.pump(revision: startRevision) }
    }

    /// Ordered teardown. The revision is bumped *before* the pump is cancelled,
    /// so a `receiveProtectedPacket` that unblocks with `CancellationError`
    /// takes the silent-stop path instead of reporting a terminal failure.
    ///
    /// This awaits the pump task, which relies on
    /// `DiscordVoiceMediaDatagramTransport.receiveProtectedPacket()` being
    /// cancellation-aware — the loop does not own the socket and must not close
    /// it, so cancellation is the only thing that can unblock the pump.
    public func stop() async {
        revision &+= 1
        let task = pumpTask
        pumpTask = nil
        task?.cancel()
        if let task { await task.value }
        if phase == .receiving {
            phase = .stopped
        }
        streams.removeAll()
        mixQueue.removeAll()
    }

    private func pump(revision startRevision: UInt64) async {
        while true {
            guard revision == startRevision, !Task.isCancelled else { return }
            let packet: [UInt8]
            do {
                packet = try await transport.receiveProtectedPacket()
            } catch {
                // A deliberate `stop()` bumped the revision before cancelling,
                // so an intact revision here is a real transport failure.
                guard revision == startRevision else { return }
                await failReceive(revision: startRevision)
                return
            }
            guard revision == startRevision, !Task.isCancelled else { return }
            let shouldContinue = await handle(packet, revision: startRevision)
            guard shouldContinue else { return }
        }
    }

    /// Returns `false` when the pump must stop (terminal failure or supersession).
    private func handle(_ packet: [UInt8], revision startRevision: UInt64) async -> Bool {
        receivedPacketCount &+= 1

        let header: DiscordVoiceRTPHeader
        do {
            header = try codec.decodeHeader(from: packet)
        } catch DiscordVoiceRTPError.unexpectedPayloadType(_) {
            // Well-formed framing carrying something this layer does not decode
            // (RTX, RTCP-shaped payload types). Discord multiplexes these on the
            // same socket; ending the loop here would break receive outright.
            ignoredPacketCount &+= 1
            return true
        } catch {
            // Genuinely malformed framing: truncated below the base header, bad
            // version, truncated CSRC list or extension.
            await failReceive(revision: startRevision)
            return false
        }

        guard header.payloadType == DiscordVoiceRTPHeader.discordAudioPayloadType else {
            ignoredPacketCount &+= 1
            return true
        }

        let now = clock.now()
        evictIdleStreams(now: now)

        let ssrc = header.ssrc
        if streams[ssrc] == nil {
            guard streams.count < configuration.maximumStreams else {
                // Bounded by construction: a sender spraying fresh SSRCs cannot
                // grow per-stream state past the cap, whatever the idle timeout.
                rejectedStreamCount &+= 1
                return true
            }
            do {
                streams[ssrc] = try DiscordVoiceStreamJitterBuffer(
                    configuration: configuration,
                    now: now
                )
            } catch {
                droppedPacketCount &+= 1
                return true
            }
            mixQueue.register(ssrc: ssrc)
        }

        guard streams[ssrc] != nil else { return true }
        // Subscript-modify keeps the insert in place rather than copying the
        // stream's pending map out and back.
        let outcome = streams[ssrc]!.insert(
            sequence: header.sequence,
            packet: packet,
            now: now
        )
        if outcome.rejection != nil {
            rejectedPacketCount &+= 1
            return true
        }

        for release in outcome.releases {
            switch release {
            case .packet(_, let bytes):
                do {
                    let decoded = try await decoder.decodeAudioFrame(packet: bytes)
                    guard revision == startRevision else { return false }
                    guard decoded.ssrc == ssrc else {
                        // The plane attributed the frame to a different stream
                        // than the header routed it to. Fail closed rather than
                        // mixing audio into the wrong speaker's slot.
                        droppedPacketCount &+= 1
                        continue
                    }
                    decodedFrameCount &+= 1
                    mixQueue.append(decoded.pcm, ssrc: ssrc)
                } catch {
                    // Fail closed: AEAD, DAVE, or Opus refused the packet. No
                    // audio is produced and the drop is counted; one bad packet
                    // does not end the session.
                    guard revision == startRevision else { return false }
                    droppedPacketCount &+= 1
                }
            case .conceal:
                do {
                    let pcm = try await decoder.concealAudioFrame(ssrc: ssrc)
                    guard revision == startRevision else { return false }
                    concealedFrameCount &+= 1
                    mixQueue.append(pcm, ssrc: ssrc)
                } catch {
                    guard revision == startRevision else { return false }
                    droppedPacketCount &+= 1
                }
            }
        }

        for mixed in mixQueue.drainReadyFrames() {
            do {
                try await sink.play(pcm: mixed)
            } catch {
                guard revision == startRevision else { return false }
                await failReceive(revision: startRevision)
                return false
            }
            guard revision == startRevision else { return false }
            mixedFrameCount &+= 1
        }
        return true
    }

    private func evictIdleStreams(now: Duration) {
        guard !streams.isEmpty else { return }
        let timeout = configuration.idleTimeout
        let expired = streams.filter { now - $0.value.lastActivity >= timeout }
        for (ssrc, _) in expired {
            streams.removeValue(forKey: ssrc)
            mixQueue.remove(ssrc: ssrc)
            evictedStreamCount &+= 1
        }
    }

    private func failReceive(revision startRevision: UInt64) async {
        guard revision == startRevision else { return }
        revision &+= 1
        phase = .failed
        pumpTask = nil
        streams.removeAll()
        mixQueue.removeAll()
        if let terminalHandler {
            // Detached so a handler that calls back into `stop()` cannot
            // deadlock against the pump task it is running on.
            Task { await terminalHandler() }
        }
    }
}
