import AbbeyCore
import Foundation

/// Fail-closed errors from the native negotiated-media bootstrap.
///
/// These cases intentionally omit identifiers, transport modes, generations,
/// and native error details so an installation failure cannot become a side
/// channel for the one-shot transport authority.
public enum DiscordVoiceNativeMediaPlaneError: Error, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    case installationInterrupted
    case nativeComponentsUnavailable
    case daveSessionUnavailable
    /// A send was requested before any generation finished `install(_:)`.
    case mediaNotInstalled
    /// The installed generation exists but never attested a ready DAVE
    /// session (protocol version 0 or an unattested session). Discord's
    /// current calls require DAVE-protected media, so this path refuses to
    /// send rather than fall back to transport-only or plaintext protection.
    case daveProtectionRequired
    /// The Voice Gateway session's Speaking callback failed or was rejected;
    /// no packet is sent without a preceding Speaking signal.
    case speakingSignalFailed
    /// The installed generation was superseded (reset or a new install) while
    /// a send was suspended on native or transport work.
    case sendInterrupted
    /// A video send was requested before `installVideoSource(...)` bound a
    /// server-assigned video SSRC allocation to the installed generation.
    case videoSourceNotInstalled
    /// The offered video source does not belong to this connection (its audio
    /// SSRC differs from the installed generation's) or names a codec with no
    /// modeled Discord RTP payload type.
    case videoSourceInvalid
    /// The Opcode 12 Video announcement callback is missing, failed, or was
    /// rejected; Discord requires the announcement before video media, so no
    /// video packet is sent without it.
    case videoAnnouncementSignalFailed
    /// The caller offered an empty encoded video frame.
    case videoFrameInvalid

    public var description: String {
        switch self {
        case .installationInterrupted:
            "Native Discord media installation was interrupted"
        case .nativeComponentsUnavailable:
            "Native Discord media components are unavailable"
        case .daveSessionUnavailable:
            "Native DAVE media state is unavailable"
        case .mediaNotInstalled:
            "Native Discord media has no installed generation"
        case .daveProtectionRequired:
            "Native Discord media send requires an attested DAVE session"
        case .speakingSignalFailed:
            "Native Discord media Speaking signal failed"
        case .sendInterrupted:
            "Native Discord media send was interrupted"
        case .videoSourceNotInstalled:
            "Native Discord media has no installed video source"
        case .videoSourceInvalid:
            "Native Discord media video source does not belong to this connection"
        case .videoAnnouncementSignalFailed:
            "Native Discord media video announcement failed"
        case .videoFrameInvalid:
            "Native Discord media video frame is invalid"
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["nativeMedia": "<redacted>"], displayStyle: .enum)
    }
}

/// The narrow media-facing view of the active DAVE session.
///
/// Keeping this protocol internal makes the Phase 4 bootstrap testable without
/// widening AbbeyMediaNative's public API or exposing libdave session objects.
protocol DiscordVoiceNativeDAVEMediaSession: Sendable {
    var protocolVersion: UInt16 { get async }
    var isMediaReady: Bool { get async }

    /// Applies the real MLS/DAVE media protection to one media frame. This is
    /// the exact boundary the Phase 5 send path calls; nothing between the
    /// Opus encoder and this call may substitute for it.
    func protect(
        _ frame: Data,
        mediaType: NativeDAVEMediaType,
        codec: NativeDAVECodec,
        ssrc: UInt32
    ) async throws -> Data
}

extension NativeDAVESession: DiscordVoiceNativeDAVEMediaSession {}

/// Session-owned native media bootstrap for one Discord Voice connection.
///
/// Installation consumes the capability's secret by constructing the existing
/// single-owner RTPSIZE encryption actor. No property, snapshot, reflection, or
/// error exposes the raw key, SSRC, generation, transport mode, or DAVE state.
public actor DiscordVoiceNativeMediaPlane: DiscordVoiceMediaPlane,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public struct Snapshot: Equatable, Sendable, CustomStringConvertible {
        public let isInstalled: Bool

        public var description: String {
            "DiscordVoiceNativeMediaPlane.Snapshot(isInstalled: \(isInstalled))"
        }
    }

    typealias DAVESessionProvider = @Sendable () async ->
        (any DiscordVoiceNativeDAVEMediaSession)?
    typealias AEADPrimitiveFactory = @Sendable (DiscordVoiceTransportMode) throws ->
        any DiscordVoiceAEADPrimitive
    typealias OpusFactory = @Sendable () throws -> Opus20msCodec
    /// Seeds the per-generation RTP clock. Production uses the system CSPRNG
    /// (Discord recommends an unpredictable initial sequence/timestamp);
    /// tests inject a fixed pair so packet fixtures stay deterministic.
    typealias RTPClockSeedFactory = @Sendable () -> (sequence: UInt16, timestamp: UInt32)

    private struct InstalledRuntime: Sendable {
        let transportEncryption: DiscordVoiceTransportEncryption
        let opus: Opus20msCodec
        let datagramTransport: any DiscordVoiceMediaDatagramTransport
        let ssrc: UInt32
        /// True only when `install`/`updateDAVEProtocolVersion` attested a
        /// ready DAVE session for a nonzero negotiated protocol version.
        /// `sendAudioFrame` refuses to run while this is false so a
        /// transport-only or DAVE-less generation can never emit media.
        let daveReady: Bool
    }

    public nonisolated let aes256GCMAvailable: Bool

    private let generationStore = DiscordVoiceNegotiatedMediaStore()
    private let daveSessionProvider: DAVESessionProvider
    private let datagramTransport: any DiscordVoiceMediaDatagramTransport
    private let makeAEADPrimitive: AEADPrimitiveFactory
    private let makeOpus: OpusFactory
    private let makeRTPClockSeed: RTPClockSeedFactory

    /// One installed outbound video source: the server-assigned SSRC selected
    /// by an Opcode 12 announcement, the DAVE codec label for `protect`, the
    /// negotiated RTP payload type, and the exact announcement that must be
    /// sent before this source's first packet.
    private struct InstalledVideoSource: Sendable {
        let ssrc: UInt32
        let codec: NativeDAVECodec
        let payloadType: UInt8
        let announcement: VoiceGatewayV8Video
    }

    private var highestGeneration: UInt64?
    private var revision: UInt64 = 0
    private var runtime: InstalledRuntime?
    private var clock: DiscordVoiceRTPClock?
    private var speakingSignal: (@Sendable () async throws -> Void)?

    /// One-shot-per-generation Speaking obligation, shared across concurrent
    /// sends. `.inFlight` carries the single signaling task so a frame that
    /// arrives while the first frame's callback is suspended awaits the SAME
    /// outcome instead of racing past the gate; a failed callback regresses
    /// the gate to `.pending` so the next frame re-attempts opcode 5 rather
    /// than silently skipping it.
    private enum OneShotSignalGate {
        case pending
        case inFlight(Task<Void, any Error>)
        case sent
    }

    /// Which pre-media signal a gate guards. Audio and video deliberately
    /// share one gate implementation: this logic was written twice, and the
    /// second copy reintroduced the eager-latch bug the first had just fixed.
    private enum SignalKind {
        case speaking
        case videoAnnouncement

        var failure: DiscordVoiceNativeMediaPlaneError {
            switch self {
            case .speaking: .speakingSignalFailed
            case .videoAnnouncement: .videoAnnouncementSignalFailed
            }
        }

        /// Discord documents Opcode 12 as mandatory before video media, so a
        /// missing video callback fails closed. An absent Speaking callback
        /// keeps the pre-existing audio behavior: nothing to signal, and
        /// nothing to re-attempt.
        var requiresSignal: Bool { self == .videoAnnouncement }
    }

    private var speakingGate: OneShotSignalGate = .pending
    private var videoAnnouncementGate: OneShotSignalGate = .pending

    /// Suspended datagram sends, keyed for interruption: `reset()` cancels and
    /// awaits every entry so an obsolete generation's packet cannot reach the
    /// wire during or after teardown.
    private var inFlightSends: [UInt64: Task<Void, any Error>] = [:]
    private var nextSendID: UInt64 = 0
    private var videoSource: InstalledVideoSource?
    private var videoClock: DiscordVoiceVideoRTPClock?
    private var videoAnnouncementSignal: (@Sendable (VoiceGatewayV8Video) async throws -> Void)?


    public init(
        daveAdapter: NativeDAVEControlAdapter,
        datagramTransport: any DiscordVoiceMediaDatagramTransport
    ) {
        self.aes256GCMAvailable = NativeDiscordVoiceAEADPrimitive.isAvailable(
            .aeadAES256GCMRTPSIZE
        )
        self.daveSessionProvider = { await daveAdapter.mediaSession() }
        self.datagramTransport = datagramTransport
        self.makeAEADPrimitive = { try NativeDiscordVoiceAEADPrimitive(mode: $0) }
        self.makeOpus = { try Opus20msCodec() }
        self.makeRTPClockSeed = {
            (UInt16.random(in: .min ... .max), UInt32.random(in: .min ... .max))
        }
    }

    init(
        aes256GCMAvailable: Bool,
        daveSessionProvider: @escaping DAVESessionProvider,
        datagramTransport: any DiscordVoiceMediaDatagramTransport,
        makeAEADPrimitive: @escaping AEADPrimitiveFactory = {
            try NativeDiscordVoiceAEADPrimitive(mode: $0)
        },
        makeOpus: @escaping OpusFactory = { try Opus20msCodec() },
        makeRTPClockSeed: @escaping RTPClockSeedFactory = {
            (UInt16.random(in: .min ... .max), UInt32.random(in: .min ... .max))
        }
    ) {
        self.aes256GCMAvailable = aes256GCMAvailable
        self.daveSessionProvider = daveSessionProvider
        self.datagramTransport = datagramTransport
        self.makeAEADPrimitive = makeAEADPrimitive
        self.makeOpus = makeOpus
        self.makeRTPClockSeed = makeRTPClockSeed
    }

    public nonisolated var description: String {
        "DiscordVoiceNativeMediaPlane(<redacted>)"
    }

    public nonisolated var debugDescription: String { description }

    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["nativeMedia": "<redacted>"], displayStyle: .class)
    }

    public func snapshot() -> Snapshot {
        Snapshot(isInstalled: runtime != nil)
    }

    /// Test/next-phase seam only; the SSRC never enters public diagnostics.
    func hasInstalledSource(_ ssrc: UInt32) -> Bool {
        runtime?.ssrc == ssrc
    }

    public func install(
        _ capability: DiscordVoiceNegotiatedMediaCapability
    ) async throws -> DiscordVoiceMediaCapabilities {
        try acceptGeneration(capability.generation)
        revision &+= 1
        let installationRevision = revision
        clearRuntime()

        do {
            try await generationStore.install(capability)
            try requireCurrent(installationRevision)

            let primitive = try makeAEADPrimitive(capability.transportMode)
            let transportEncryption = try capability.makeTransportEncryption(
                primitive: primitive
            )
            let opus = try makeOpus()

            let daveAvailable = try await attestDAVE(
                protocolVersion: capability.daveProtocolVersion,
                revision: installationRevision
            )
            try requireCurrent(installationRevision)

            runtime = InstalledRuntime(
                transportEncryption: transportEncryption,
                opus: opus,
                datagramTransport: datagramTransport,
                ssrc: capability.ssrc,
                daveReady: daveAvailable
            )
            let seed = makeRTPClockSeed()
            clock = try DiscordVoiceRTPClock(
                initialSequence: seed.sequence,
                initialTimestamp: seed.timestamp
            )
            speakingGate = .pending
            return DiscordVoiceMediaCapabilities(
                dave: daveAvailable,
                aead: true,
                opus: true
            )
        } catch let error as DiscordVoiceNegotiatedMediaError {
            if revision == installationRevision {
                clearRuntime()
                await generationStore.reset()
            }
            throw error
        } catch let error as DiscordVoiceNativeMediaPlaneError {
            if revision == installationRevision {
                clearRuntime()
                await generationStore.reset()
            }
            throw error
        } catch {
            if revision == installationRevision {
                clearRuntime()
                await generationStore.reset()
            }
            throw DiscordVoiceNativeMediaPlaneError.nativeComponentsUnavailable
        }
    }

    /// Re-attests the adapter's current DAVE session after an executed Voice
    /// Gateway transition. The media plane never caches the returned native
    /// session, so subsequent packet work cannot retain an obsolete epoch.
    /// The RTP clock and one-shot Speaking gate survive a re-attestation of
    /// the same generation; only a fresh `install(_:)` or `reset()` clears
    /// them, since this is still the same outgoing media stream.
    public func updateDAVEProtocolVersion(
        _ version: UInt16,
        generation: UInt64
    ) async throws -> DiscordVoiceMediaCapabilities {
        guard highestGeneration == generation, let installedRuntime = runtime else {
            throw DiscordVoiceNegotiatedMediaError.staleInstallation
        }

        revision &+= 1
        let updateRevision = revision
        runtime = nil
        if version == 0 {
            await generationStore.reset()
            return DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false)
        }
        do {
            let daveAvailable = try await attestDAVE(
                protocolVersion: version,
                revision: updateRevision
            )
            try requireCurrent(updateRevision)
            runtime = InstalledRuntime(
                transportEncryption: installedRuntime.transportEncryption,
                opus: installedRuntime.opus,
                datagramTransport: installedRuntime.datagramTransport,
                ssrc: installedRuntime.ssrc,
                daveReady: daveAvailable
            )
            return DiscordVoiceMediaCapabilities(
                dave: daveAvailable,
                aead: true,
                opus: true
            )
        } catch let error as DiscordVoiceNativeMediaPlaneError {
            if revision == updateRevision {
                runtime = nil
                await generationStore.reset()
            }
            throw error
        } catch {
            if revision == updateRevision {
                runtime = nil
                await generationStore.reset()
            }
            throw DiscordVoiceNativeMediaPlaneError.nativeComponentsUnavailable
        }
    }

    /// Lets the owning Voice Gateway session provide the Speaking callback.
    /// Stored, not invoked; `sendAudioFrame` calls it at most once per
    /// installed generation, before the first protected packet.
    public func attachSpeakingSignal(
        _ signal: @escaping @Sendable () async throws -> Void
    ) async {
        speakingSignal = signal
    }

    /// Encodes one 20 ms PCM frame, applies DAVE media protection, builds and
    /// RTPSIZE-protects the RTP packet, then sends it through the retained
    /// UDP socket. This is the Phase 5 send path: every step is real
    /// (`Opus20msCodec`, the installed `NativeDAVESession`,
    /// `DiscordVoiceRTPCodec`/`DiscordVoiceRTPClock`,
    /// `DiscordVoiceTransportEncryption`, and the retained
    /// `DiscordVoiceMediaDatagramTransport`), and the current revision is
    /// re-checked after every suspension so a `reset()` or superseding
    /// `install(_:)` cannot let a stale generation reach the socket.
    ///
    /// Fails closed, never falling back to unprotected media, when: no
    /// generation is installed, the installed generation never attested a
    /// ready DAVE session, the Speaking callback fails, DAVE protection
    /// fails, or the installation is superseded mid-send.
    public func sendAudioFrame(pcm: [Int16]) async throws {
        guard let installed = runtime, var reservedClock = clock, installed.daveReady else {
            throw runtime == nil
                ? DiscordVoiceNativeMediaPlaneError.mediaNotInstalled
                : DiscordVoiceNativeMediaPlaneError.daveProtectionRequired
        }
        let sendRevision = revision

        // This actor can be re-entered while a send is suspended on native or
        // transport work. Everything below this point that must not race a
        // concurrent send — the RTP tick and the one-shot Speaking
        // obligation — is reserved here, synchronously, before this call's
        // first `await`. This mirrors how `DiscordVoiceTransportEncryption`
        // reserves its AEAD send counter before its own first suspension, so
        // two overlapping sends can never observe or emit the same RTP
        // sequence number, and at most one of them owns firing Speaking.
        let tick = reservedClock.next()
        clock = reservedClock

        // The Speaking obligation is marked satisfied only AFTER the callback
        // succeeds. A throwing callback regresses the gate so the next frame
        // re-attempts opcode 5 instead of reaching the UDP transport with no
        // successful Speaking on record, and a concurrent frame that enters
        // while the first callback is suspended awaits that same shared
        // outcome rather than bypassing the gate.
        try await runOnce(.speaking, signal: speakingSignal, revision: sendRevision)

        let opusPayload = try await installed.opus.encode(pcm)
        try requireCurrent(sendRevision, orThrow: .sendInterrupted)

        guard let daveSession = await daveSessionProvider() else {
            throw DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable
        }
        try requireCurrent(sendRevision, orThrow: .sendInterrupted)

        // DAVE protection is applied to the raw Opus payload before it ever
        // becomes an RTP body; nothing downstream can substitute plaintext.
        let protectedFrame = try await daveSession.protect(
            Data(opusPayload),
            mediaType: .audio,
            codec: .opus,
            ssrc: installed.ssrc
        )
        try requireCurrent(sendRevision, orThrow: .sendInterrupted)

        let header = try DiscordVoiceRTPHeader(
            sequence: tick.sequence,
            timestamp: tick.timestamp,
            ssrc: installed.ssrc
        )
        let rtpCodec = try DiscordVoiceRTPCodec()
        let plaintextPacket = try rtpCodec.encode(header) + Array(protectedFrame)

        let wirePacket = try await installed.transportEncryption.seal(plaintextPacket)
        try requireCurrent(sendRevision, orThrow: .sendInterrupted)

        try await sendTracked(wirePacket, through: installed.datagramTransport)
    }

    private func gate(_ kind: SignalKind) -> OneShotSignalGate {
        switch kind {
        case .speaking: speakingGate
        case .videoAnnouncement: videoAnnouncementGate
        }
    }

    private func setGate(_ kind: SignalKind, _ value: OneShotSignalGate) {
        switch kind {
        case .speaking: speakingGate = value
        case .videoAnnouncement: videoAnnouncementGate = value
        }
    }

    /// Runs a pre-media signal at most once per installed generation. At most
    /// one task exists per gate and every concurrent send shares its outcome.
    /// Success latches `.sent`; failure regresses to `.pending` (unless a reset
    /// or superseding install already replaced the gate) and fails this send
    /// closed — so no frame reaches the transport without a signal that
    /// actually succeeded, and a failed signal is re-attempted rather than
    /// silently consumed.
    private func runOnce(
        _ kind: SignalKind,
        signal: (@Sendable () async throws -> Void)?,
        revision sendRevision: UInt64
    ) async throws {
        switch gate(kind) {
        case .sent:
            return
        case .inFlight(let task):
            do {
                try await task.value
            } catch {
                throw kind.failure
            }
            try requireCurrent(sendRevision, orThrow: .sendInterrupted)
        case .pending:
            guard let signal else {
                if kind.requiresSignal { throw kind.failure }
                setGate(kind, .sent)
                return
            }
            let task = Task { try await signal() }
            setGate(kind, .inFlight(task))
            do {
                try await task.value
            } catch {
                if case .inFlight(let current) = gate(kind), current == task {
                    setGate(kind, .pending)
                }
                throw kind.failure
            }
            if case .inFlight(let current) = gate(kind), current == task {
                setGate(kind, .sent)
            }
            try requireCurrent(sendRevision, orThrow: .sendInterrupted)
        }
    }

    /// Sends one already-sealed packet as a tracked, cancellable task so
    /// `reset()` can interrupt a send suspended inside the transport and await
    /// it before teardown finishes — an obsolete generation's packet must never
    /// reach the wire after reset returns.
    private func sendTracked(
        _ wirePacket: [UInt8],
        through transport: any DiscordVoiceMediaDatagramTransport
    ) async throws {
        let sendID = nextSendID
        nextSendID &+= 1
        let sendTask = Task { try await transport.sendProtectedPacket(wirePacket) }
        inFlightSends[sendID] = sendTask
        defer { inFlightSends[sendID] = nil }
        do {
            try await sendTask.value
        } catch is CancellationError {
            throw DiscordVoiceNativeMediaPlaneError.sendInterrupted
        }
    }

    /// Lets the owning Voice Gateway session provide the Opcode 12 Video
    /// announcement callback. Stored, not invoked; `sendVideoFrame` calls it
    /// at most once per installed video source, before that source's first
    /// protected packet, with the exact announcement built by
    /// `installVideoSource(...)`.
    public func attachVideoAnnouncementSignal(
        _ signal: @escaping @Sendable (VoiceGatewayV8Video) async throws -> Void
    ) async {
        videoAnnouncementSignal = signal
    }

    /// Binds one server-assigned outbound video source to the installed
    /// generation. The allocation comes from the bounded Voice Gateway video
    /// signaling models (Ready stream/SSRC assignment); clients never invent
    /// video SSRCs. Fails closed when no generation is installed, when the
    /// installed generation never attested a ready DAVE session, when the
    /// allocation belongs to a different connection (audio SSRC mismatch), or
    /// when the codec has no modeled Discord RTP payload type. Installing a
    /// source re-arms the one-shot announcement obligation and seeds a fresh
    /// 90 kHz video RTP clock.
    ///
    /// Boundary honesty: no camera/screen capture, video encoder, or codec
    /// negotiation exists behind this call — it only fixes which SSRC,
    /// payload type, and DAVE codec label the video send path composes.
    public func installVideoSource(
        allocation: VoiceGatewayV8VideoSSRCAllocation,
        activeRIDs: Set<String>,
        codec: NativeDAVECodec,
        ticksPerFrame: UInt32 = DiscordVoiceVideoRTPClock.defaultTicksPerFrame
    ) throws {
        guard let installed = runtime else {
            throw DiscordVoiceNativeMediaPlaneError.mediaNotInstalled
        }
        guard installed.daveReady else {
            throw DiscordVoiceNativeMediaPlaneError.daveProtectionRequired
        }
        guard allocation.audioSSRC == installed.ssrc else {
            throw DiscordVoiceNativeMediaPlaneError.videoSourceInvalid
        }
        let payloadType = try Self.rtpPayloadType(for: codec)
        let announcement = try allocation.announcement(activeRIDs: activeRIDs)
        let seed = makeRTPClockSeed()
        videoClock = try DiscordVoiceVideoRTPClock(
            initialSequence: seed.sequence,
            initialTimestamp: seed.timestamp,
            ticksPerFrame: ticksPerFrame
        )
        videoSource = InstalledVideoSource(
            ssrc: announcement.videoSSRC,
            codec: codec,
            payloadType: payloadType,
            announcement: announcement
        )
        videoAnnouncementGate = .pending
    }

    /// Applies DAVE video-frame protection to one already-encoded video frame
    /// (a complete access unit), builds and RTPSIZE-protects the video RTP
    /// packet, then sends it through the retained UDP socket. This composes
    /// the same Phase 5 boundary as `sendAudioFrame` for `.video` media: the
    /// installed `NativeDAVESession.protect` with the video frame type and
    /// negotiated codec label, the 90 kHz `DiscordVoiceVideoRTPClock`, the
    /// negotiated video RTP payload type with the marker bit set on the frame
    /// boundary (this slice sends one whole frame per packet; MTU
    /// packetization is a later boundary), the shared
    /// `DiscordVoiceTransportEncryption` AEAD counter, and the retained
    /// datagram transport. The current revision is re-checked after every
    /// suspension so a `reset()` or superseding `install(_:)` cannot let a
    /// stale generation reach the socket.
    ///
    /// Fails closed, never falling back to unprotected media, when: no
    /// generation is installed, the installed generation never attested a
    /// ready DAVE session, no video source is installed, the frame is empty,
    /// the Opcode 12 announcement callback is missing or fails (Discord
    /// requires the announcement before video media — unlike Speaking there
    /// is no tolerated absent-callback path), DAVE protection fails, or the
    /// installation is superseded mid-send.
    ///
    /// Boundary honesty: callers must supply frames already encoded by a
    /// negotiated codec. No capture pipeline, encoder, or codec negotiation
    /// completion ships behind this call.
    public func sendVideoFrame(encodedFrame: Data) async throws {
        guard let installed = runtime else {
            throw DiscordVoiceNativeMediaPlaneError.mediaNotInstalled
        }
        guard installed.daveReady else {
            throw DiscordVoiceNativeMediaPlaneError.daveProtectionRequired
        }
        guard let videoSource, var reservedClock = videoClock else {
            throw DiscordVoiceNativeMediaPlaneError.videoSourceNotInstalled
        }
        guard !encodedFrame.isEmpty else {
            throw DiscordVoiceNativeMediaPlaneError.videoFrameInvalid
        }
        let sendRevision = revision

        // Reserve the RTP tick and the one-shot announcement obligation
        // synchronously, before this call's first `await`, exactly like the
        // audio path reserves its tick and Speaking obligation: two
        // overlapping sends can never observe or emit the same video RTP
        // sequence number, and at most one of them owns the announcement.
        let tick = reservedClock.next()
        videoClock = reservedClock
        // Bind the stored callback to this source's announcement so the shared
        // gate can treat audio and video uniformly. Written as an explicit
        // if-let: the equivalent `Optional.map` with a nested @Sendable async
        // closure defeats the type checker.
        let boundAnnouncement: (@Sendable () async throws -> Void)?
        if let videoAnnouncementSignal {
            let announcement = videoSource.announcement
            boundAnnouncement = { try await videoAnnouncementSignal(announcement) }
        } else {
            boundAnnouncement = nil
        }
        try await runOnce(
            .videoAnnouncement,
            signal: boundAnnouncement,
            revision: sendRevision
        )

        guard let daveSession = await daveSessionProvider() else {
            throw DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable
        }
        try requireCurrent(sendRevision, orThrow: .sendInterrupted)

        // DAVE protection is applied to the raw encoded frame before it ever
        // becomes an RTP body; nothing downstream can substitute plaintext.
        let protectedFrame = try await daveSession.protect(
            encodedFrame,
            mediaType: .video,
            codec: videoSource.codec,
            ssrc: videoSource.ssrc
        )
        try requireCurrent(sendRevision, orThrow: .sendInterrupted)

        let header = try DiscordVoiceRTPHeader(
            marker: true,
            payloadType: videoSource.payloadType,
            sequence: tick.sequence,
            timestamp: tick.timestamp,
            ssrc: videoSource.ssrc
        )
        let rtpCodec = try DiscordVoiceRTPCodec()
        let plaintextPacket = try rtpCodec.encode(header) + Array(protectedFrame)

        let wirePacket = try await installed.transportEncryption.seal(plaintextPacket)
        try requireCurrent(sendRevision, orThrow: .sendInterrupted)

        try await sendTracked(wirePacket, through: installed.datagramTransport)
    }

    /// Drops every object that can retain the transport key while preserving
    /// the generation high-water mark against late installation tasks.
    /// Interrupts and awaits every suspended datagram send so teardown cannot
    /// complete while an obsolete packet could still be put on the wire.
    public func reset() async {
        revision &+= 1
        clearRuntime()
        let pending = Array(inFlightSends.values)
        inFlightSends.removeAll(keepingCapacity: false)
        for task in pending { task.cancel() }
        for task in pending { _ = try? await task.value }
        await generationStore.reset()
    }

    private func clearRuntime() {
        runtime = nil
        clock = nil
        speakingGate = .pending
        videoSource = nil
        videoClock = nil
        videoAnnouncementGate = .pending
    }

    /// Maps a negotiated DAVE video codec label to the client-proposed
    /// Discord RTP payload type. Opus is not a video codec, and H.265 has no
    /// modeled Discord payload type here; both fail closed rather than guess.
    private static func rtpPayloadType(for codec: NativeDAVECodec) throws -> UInt8 {
        switch codec {
        case .h264: return DiscordVoiceRTPHeader.discordVideoH264PayloadType
        case .vp8: return DiscordVoiceRTPHeader.discordVideoVP8PayloadType
        case .vp9: return DiscordVoiceRTPHeader.discordVideoVP9PayloadType
        case .av1: return DiscordVoiceRTPHeader.discordVideoAV1PayloadType
        case .opus, .h265:
            throw DiscordVoiceNativeMediaPlaneError.videoSourceInvalid
        }

    }

    private func acceptGeneration(_ generation: UInt64) throws {
        if let highestGeneration {
            if generation == highestGeneration {
                throw DiscordVoiceNegotiatedMediaError.duplicateInstallation
            }
            if generation < highestGeneration {
                throw DiscordVoiceNegotiatedMediaError.staleInstallation
            }
        }
        highestGeneration = generation
    }

    private func requireCurrent(
        _ expectedRevision: UInt64,
        orThrow error: DiscordVoiceNativeMediaPlaneError = .installationInterrupted
    ) throws {
        guard revision == expectedRevision, !Task.isCancelled else {
            throw error
        }
    }

    private func attestDAVE(
        protocolVersion: UInt16,
        revision expectedRevision: UInt64
    ) async throws -> Bool {
        guard protocolVersion > 0 else { return false }
        guard let candidate = await daveSessionProvider() else {
            throw DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable
        }
        try requireCurrent(expectedRevision)
        guard await candidate.protocolVersion == protocolVersion else {
            throw DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable
        }
        try requireCurrent(expectedRevision)
        guard await candidate.isMediaReady else {
            throw DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable
        }
        try requireCurrent(expectedRevision)
        return true
    }
}
