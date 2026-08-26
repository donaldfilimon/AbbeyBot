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
    /// The installed generation was superseded (reset or a new install), or —
    /// for a video send — the installed video source was superseded by a later
    /// `installVideoSource(...)`, while a send was suspended on native or
    /// transport work.
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
    /// A received packet failed RTPSIZE transport authentication: a bad tag, a
    /// replayed or too-old AEAD counter, or an exhausted source table.
    ///
    /// Receive deliberately classifies instead of propagating the underlying
    /// error, which the send path does. Receive input is attacker-controlled,
    /// and `DiscordVoiceTransportEncryptionError.duplicateNonce(ssrc:nonce:)`
    /// / `.nonceTooOld(ssrc:nonce:)` carry the SSRC and the AEAD counter — a
    /// readout of replay-window state that must not reach a packet-driven
    /// caller. Every receive case below is payload-free for the same reason;
    /// operators get counts from `receiveDiagnostics()`, not values.
    case receiveTransportAuthenticationFailed
    /// A received packet authenticated at the transport but failed DAVE
    /// `unprotect`: no MLS participant for the claimed sender, a bad MLS tag,
    /// or an unhealthy session.
    case receiveDAVEUnprotectFailed
    /// A received packet is not a well-formed RTP packet, or carries no
    /// payload once its header and RFC 3550 padding are removed.
    case receivePacketMalformed
    /// A received packet is well-formed RTP for a payload type this receive
    /// path does not decode (the negotiated video payload types). Kept
    /// distinct from `.receivePacketMalformed` so a portable receive loop can
    /// drop foreign media quietly instead of treating it as a fault.
    case receiveMediaTypeUnsupported
    /// The Opus decoder for the authenticated source could not be created, or
    /// rejected the unprotected payload.
    case receiveDecodeFailed
    /// The installed generation was superseded (reset or a new install) while
    /// a receive was suspended on transport, native, or codec work.
    case receiveInterrupted
    /// Loss concealment was requested for a source that has no decoder, i.e.
    /// no packet from it has ever been authenticated on this generation.
    /// Concealment synthesizes audio from decoder state, so it is refused
    /// rather than allowed to fabricate a stream that was never authenticated.
    case receiveSourceUnknown

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
        case .receiveTransportAuthenticationFailed:
            "Native Discord media receive transport authentication failed"
        case .receiveDAVEUnprotectFailed:
            "Native Discord media receive DAVE unprotect failed"
        case .receivePacketMalformed:
            "Native Discord media received a malformed packet"
        case .receiveMediaTypeUnsupported:
            "Native Discord media receive does not decode this media type"
        case .receiveDecodeFailed:
            "Native Discord media receive decode failed"
        case .receiveInterrupted:
            "Native Discord media receive was interrupted"
        case .receiveSourceUnknown:
            "Native Discord media receive has no authenticated source state"
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

    /// Removes the real MLS/DAVE media protection from one received frame.
    /// This is the exact mirror of `protect` and the boundary the receive path
    /// calls; nothing between the transport AEAD and this call may substitute
    /// for it, and no receive path may return a payload that did not pass
    /// through it.
    ///
    /// `senderID` is the sender's Discord user ID — the MLS participant key —
    /// not an SSRC. The media plane has no SSRC-to-user mapping (it comes from
    /// Voice Gateway Speaking events, which the portable layer owns), so the
    /// caller supplies it. An incorrect mapping cannot yield audio: the frame
    /// simply fails to authenticate against that participant's ratchet.
    func unprotect(
        _ frame: Data,
        mediaType: NativeDAVEMediaType,
        senderID: UInt64
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

    /// Redacted receive telemetry: counts and one cardinality, nothing else.
    ///
    /// Every packet the receive path refuses is counted in exactly one
    /// `dropped*` bucket, so "fails closed" is observable without any error
    /// carrying an SSRC, a nonce, packet bytes, or PCM. Counts are cumulative
    /// for the lifetime of the plane and deliberately survive `reset()` — drop
    /// evidence matters most across a teardown.
    public struct ReceiveDiagnostics: Equatable, Sendable, CustomStringConvertible {
        /// Packets that produced decoded PCM.
        public let accepted: UInt64
        /// Complete H.264 access units that passed transport authentication,
        /// RFC 6184 reassembly, and DAVE unprotection.
        public let acceptedVideoAccessUnits: UInt64
        /// Loss-concealment frames synthesized by `concealAudioLoss(ssrc:)`.
        public let concealed: UInt64
        /// Refused because no generation was installed, or the installed
        /// generation never attested a ready DAVE session.
        public let droppedNotInstalled: UInt64
        /// Refused by RTPSIZE transport authentication (bad tag, replay,
        /// too-old counter, source table exhausted).
        public let droppedTransportAuthentication: UInt64
        /// Refused by the DAVE boundary (no session, or `unprotect` failed).
        public let droppedDAVE: UInt64
        /// Refused as not well-formed RTP, or as carrying no payload.
        public let droppedMalformed: UInt64
        /// Refused as a payload type this receive path does not decode.
        public let droppedMediaTypeUnsupported: UInt64
        /// Refused because the Opus decoder could not be created or rejected
        /// the unprotected payload.
        public let droppedDecode: UInt64
        /// Refused because the installed generation was superseded while the
        /// receive was suspended.
        public let droppedInterrupted: UInt64
        /// Concealment refused for a source with no authenticated decoder.
        public let droppedSourceUnknown: UInt64
        /// How many sources currently hold decoder state.
        public let activeAudioSources: Int

        public var description: String {
            "DiscordVoiceNativeMediaPlane.ReceiveDiagnostics("
                + "accepted: \(accepted), acceptedVideoAccessUnits: \(acceptedVideoAccessUnits), "
                + "concealed: \(concealed), "
                + "droppedNotInstalled: \(droppedNotInstalled), "
                + "droppedTransportAuthentication: \(droppedTransportAuthentication), "
                + "droppedDAVE: \(droppedDAVE), "
                + "droppedMalformed: \(droppedMalformed), "
                + "droppedMediaTypeUnsupported: \(droppedMediaTypeUnsupported), "
                + "droppedDecode: \(droppedDecode), "
                + "droppedInterrupted: \(droppedInterrupted), "
                + "droppedSourceUnknown: \(droppedSourceUnknown), "
                + "activeAudioSources: \(activeAudioSources))"
        }
    }

    private struct ReceiveCounters: Sendable {
        var accepted: UInt64 = 0
        var acceptedVideoAccessUnits: UInt64 = 0
        var concealed: UInt64 = 0
        var droppedNotInstalled: UInt64 = 0
        var droppedTransportAuthentication: UInt64 = 0
        var droppedDAVE: UInt64 = 0
        var droppedMalformed: UInt64 = 0
        var droppedMediaTypeUnsupported: UInt64 = 0
        var droppedDecode: UInt64 = 0
        var droppedInterrupted: UInt64 = 0
        var droppedSourceUnknown: UInt64 = 0
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
    /// Video-source generation, bumped by every `installVideoSource(...)` and
    /// by `clearRuntime()`. `revision` deliberately does NOT move when a video
    /// source is replaced — that would fail audio sends that are legitimately
    /// in flight — so `sendVideoFrame` carries this second counter and
    /// re-checks it after every suspension. Without it a send suspended on its
    /// Opcode 12 announcement or on DAVE work would pass every later
    /// `requireCurrent` check and put a frame on the wire under the superseded
    /// source's SSRC and codec.
    private var videoRevision: UInt64 = 0
    private var videoAnnouncementSignal: (@Sendable (VoiceGatewayV8Video) async throws -> Void)?

    /// RFC 6184 packetizer for the only qualified initial video codec. It is
    /// built lazily because its MTU bounds are validated and can throw.
    private func makeH264Packetizer() throws -> DiscordVoiceH264Packetizer {
        try DiscordVoiceH264Packetizer()
    }

    /// One Opus decoder per authenticated remote SSRC.
    ///
    /// Opus decoders carry per-stream state (overlap-add history, PLC state),
    /// so feeding two senders through one decoder is a correctness bug, not a
    /// style choice — and `runtime.opus` is the *encoder* used by the send
    /// path, which must never be shared with any receive stream either.
    ///
    /// These live here rather than in the portable receive layer because the
    /// dependency direction forces it: `Opus20msCodec` is an AbbeyMediaNative
    /// type and AbbeyCore (where the receive loop, jitter buffer, and mixer
    /// live) cannot name it.
    ///
    /// Entries are created only after a packet has passed **both** AEAD and
    /// DAVE, never from unauthenticated input — otherwise a spoofed SSRC spray
    /// would grow memory for free. This is why the decoder is not "reserved"
    /// before the first `await` the way the send path reserves its RTP tick:
    /// the send reservation exists to stop two concurrent sends racing shared
    /// mutable state, which receive has no analogue of. Do not "fix" this by
    /// moving decoder creation earlier.
    ///
    /// The map is bounded by construction: an SSRC only reaches decoder
    /// creation after `DiscordVoiceTransportEncryption` admitted it into its
    /// own receive-window table, which is capped at `sourceCapacity`.
    private var audioDecoders: [UInt32: Opus20msCodec] = [:]
    private var receiveCounters = ReceiveCounters()


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

        let opusPayload = try await guarded(revision: sendRevision) {
            try await installed.opus.encode(pcm)
        }

        guard let daveSession = try await guarded(revision: sendRevision, { await daveSessionProvider() }) else {
            throw DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable
        }

        // DAVE protection is applied to the raw Opus payload before it ever
        // becomes an RTP body; nothing downstream can substitute plaintext.
        let protectedFrame = try await guarded(revision: sendRevision) {
            try await daveSession.protect(
                Data(opusPayload),
                mediaType: .audio,
                codec: .opus,
                ssrc: installed.ssrc
            )
        }

        let header = try DiscordVoiceRTPHeader(
            sequence: tick.sequence,
            timestamp: tick.timestamp,
            ssrc: installed.ssrc
        )
        let rtpCodec = try DiscordVoiceRTPCodec()
        let plaintextPacket = try rtpCodec.encode(header) + Array(protectedFrame)

        let wirePacket = try await guarded(revision: sendRevision) {
            try await installed.transportEncryption.seal(plaintextPacket)
        }
        try await sendTracked(wirePacket, through: installed.datagramTransport)
    }

    // MARK: - Receive boundary (the exact mirror of `sendAudioFrame`)

    /// Authenticates one received RTPSIZE packet, removes DAVE media
    /// protection, decodes the Opus payload, and returns the PCM together with
    /// the authenticated RTP identity of its source. This is the receive half
    /// of the decryption boundary: the media plane owns the keys, and the
    /// portable layer above it never sees them, exactly as on send.
    ///
    /// The order is the strict mirror of `sendAudioFrame`:
    /// `DiscordVoiceTransportEncryption.open` → `NativeDAVESession.unprotect`
    /// → `Opus20msCodec.decode`. Every step is real, and `revision` is
    /// reserved synchronously before this call's first `await` and re-checked
    /// after every suspension, so a `reset()` or superseding `install(_:)`
    /// cannot let a superseded generation hand audio back to a caller.
    ///
    /// Fails closed — no audio, and the packet counted in exactly one
    /// `receiveDiagnostics()` bucket — when: no generation is installed, the
    /// installed generation never attested a ready DAVE session, no DAVE
    /// session is available, the packet fails transport authentication (bad
    /// tag, replay, too-old counter), the packet is not well-formed RTP or is
    /// empty, its payload type is not the negotiated audio one, DAVE
    /// `unprotect` fails, the Opus decode fails, or the installation is
    /// superseded mid-receive. There is no branch that returns a payload which
    /// did not pass through both AEAD `open` and DAVE `unprotect`.
    ///
    /// `senderID` is the sender's Discord user ID (the MLS participant key),
    /// which the caller learns from Voice Gateway Speaking events; the plane
    /// holds no SSRC-to-user mapping. A wrong mapping cannot leak audio — the
    /// frame fails to authenticate against that participant's ratchet.
    ///
    /// Contract for the portable layer (spec §2/§3): this call does **not**
    /// serialize per-SSRC decode ordering. Two concurrent calls for the same
    /// SSRC both reach that SSRC's decoder actor, in nondeterministic order.
    /// Reordering, duplicate/replay policy above the AEAD window, and
    /// concealment scheduling belong to the jitter buffer, which must feed
    /// this call one packet at a time per source and drive
    /// `concealAudioLoss(ssrc:)` for gaps it cannot fill.
    public func receiveAudioFrame(
        packet: [UInt8],
        senderID: UInt64
    ) async throws -> DiscordVoiceReceivedAudioFrame {
        guard let installed = runtime else {
            receiveCounters.droppedNotInstalled &+= 1
            throw DiscordVoiceNativeMediaPlaneError.mediaNotInstalled
        }
        guard installed.daveReady else {
            receiveCounters.droppedNotInstalled &+= 1
            throw DiscordVoiceNativeMediaPlaneError.daveProtectionRequired
        }
        // Reserved synchronously, before this call's first `await`, exactly as
        // `sendAudioFrame` reserves its own send revision.
        let receiveRevision = revision

        // No header is parsed before this point on purpose: `open` performs
        // the RTP layout and header decode itself, so everything read below
        // comes from a packet whose header was authenticated as AEAD
        // associated data. There is nothing to reconcile against an earlier
        // unauthenticated parse.
        let plaintextPacket: [UInt8]
        do {
            plaintextPacket = try await installed.transportEncryption.open(packet)
        } catch is DiscordVoiceRTPError {
            receiveCounters.droppedMalformed &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receivePacketMalformed
        } catch {
            receiveCounters.droppedTransportAuthentication &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receiveTransportAuthenticationFailed
        }
        try requireCurrentReceive(receiveRevision)

        let header: DiscordVoiceRTPHeader
        let payload: [UInt8]
        do {
            let rtpCodec = try DiscordVoiceRTPCodec()
            header = try rtpCodec.decodeHeader(from: plaintextPacket)
            let layout = try rtpCodec.plaintextLayout(in: plaintextPacket)
            payload = Array(plaintextPacket[layout.payloadRange])
        } catch {
            receiveCounters.droppedMalformed &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receivePacketMalformed
        }
        // `acceptedPayloadTypes` also admits the negotiated video payload
        // types, so `decodeHeader` succeeds on a video packet. Without this
        // gate a video payload would be handed to `unprotect(mediaType:
        // .audio)` and then to an Opus decoder.
        guard header.payloadType == DiscordVoiceRTPHeader.discordAudioPayloadType else {
            receiveCounters.droppedMediaTypeUnsupported &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receiveMediaTypeUnsupported
        }
        guard !payload.isEmpty else {
            receiveCounters.droppedMalformed &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receivePacketMalformed
        }

        guard let daveSession = await daveSessionProvider() else {
            receiveCounters.droppedDAVE &+= 1
            throw DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable
        }
        try requireCurrentReceive(receiveRevision)

        // DAVE protection is removed before the payload ever reaches the
        // decoder; nothing upstream can substitute a plaintext payload for it.
        let opusPayload: Data
        do {
            opusPayload = try await daveSession.unprotect(
                Data(payload),
                mediaType: .audio,
                senderID: senderID
            )
        } catch {
            receiveCounters.droppedDAVE &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receiveDAVEUnprotectFailed
        }
        try requireCurrentReceive(receiveRevision)

        // Decoder state is created only now: both AEAD and DAVE have accepted
        // this packet, so the SSRC below is authenticated.
        let decoder: Opus20msCodec
        do {
            decoder = try audioDecoder(for: header.ssrc)
        } catch {
            receiveCounters.droppedDecode &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receiveDecodeFailed
        }

        let pcm: [Int16]
        do {
            pcm = try await decoder.decode(Array(opusPayload))
        } catch {
            receiveCounters.droppedDecode &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receiveDecodeFailed
        }
        // Last gate before authenticated audio is handed to the caller.
        try requireCurrentReceive(receiveRevision)

        receiveCounters.accepted &+= 1
        return DiscordVoiceReceivedAudioFrame(
            ssrc: header.ssrc,
            sequence: header.sequence,
            timestamp: header.timestamp,
            pcm: pcm
        )
    }

    /// Receives one already jitter-ordered H.264 access unit. The security and
    /// codec order is the exact inverse of send: authenticate every RTPSIZE
    /// packet, validate/reassemble RFC 6184, then DAVE-unprotect the complete
    /// codec frame before it can reach VideoToolbox. Loss/reorder/RTX policy is
    /// intentionally supplied by the bounded AbbeyCore primitives above this
    /// method; a gap or mixed source/timestamp fails the whole access unit.
    public func receiveH264AccessUnit(
        packets: [[UInt8]],
        senderID: UInt64
    ) async throws -> Data {
        guard let installed = runtime else {
            receiveCounters.droppedNotInstalled &+= 1
            throw DiscordVoiceNativeMediaPlaneError.mediaNotInstalled
        }
        guard installed.daveReady else {
            receiveCounters.droppedNotInstalled &+= 1
            throw DiscordVoiceNativeMediaPlaneError.daveProtectionRequired
        }
        guard !packets.isEmpty else {
            receiveCounters.droppedMalformed &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receivePacketMalformed
        }
        guard packets.count <= DiscordVoiceVideoPacketizer.defaultMaximumFragmentsPerFrame else {
            receiveCounters.droppedMalformed &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receivePacketMalformed
        }
        let receiveRevision = revision
        let rtpCodec: DiscordVoiceRTPCodec
        do { rtpCodec = try DiscordVoiceRTPCodec() }
        catch {
            receiveCounters.droppedMalformed &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receivePacketMalformed
        }
        var depacketizer = DiscordVoiceH264Depacketizer()
        var protectedAccessUnit: [UInt8]?
        var sourceSSRC: UInt32?
        var timestamp: UInt32?

        for (packetIndex, packet) in packets.enumerated() {
            let plaintext: [UInt8]
            do { plaintext = try await installed.transportEncryption.open(packet) }
            catch is DiscordVoiceRTPError {
                receiveCounters.droppedMalformed &+= 1
                throw DiscordVoiceNativeMediaPlaneError.receivePacketMalformed
            } catch {
                receiveCounters.droppedTransportAuthentication &+= 1
                throw DiscordVoiceNativeMediaPlaneError.receiveTransportAuthenticationFailed
            }
            try requireCurrentReceive(receiveRevision)
            do {
                let header = try rtpCodec.decodeHeader(from: plaintext)
                let layout = try rtpCodec.plaintextLayout(in: plaintext)
                guard header.payloadType == DiscordVoiceRTPHeader.discordVideoH264PayloadType else {
                    throw DiscordVoiceNativeMediaPlaneError.receiveMediaTypeUnsupported
                }
                // This API accepts exactly one access unit. Its authenticated
                // marker must therefore appear exactly once, on the final
                // supplied packet; mixed sources/timestamps are malformed too.
                // Without this gate, a completed unit followed by an unmarked
                // partial unit was silently ignored and the first unit reached
                // DAVE despite the malformed packet list.
                guard sourceSSRC == nil || sourceSSRC == header.ssrc,
                      timestamp == nil || timestamp == header.timestamp,
                      header.marker == (packetIndex == packets.count - 1)
                else { throw DiscordVoiceH264RTPError.incompleteFragment }
                sourceSSRC = header.ssrc
                timestamp = header.timestamp
                let fragment = DiscordVoiceVideoRTPFragment(
                    header: header,
                    payload: Array(plaintext[layout.payloadRange])
                )
                if let completed = try depacketizer.insert(fragment) {
                    guard protectedAccessUnit == nil else {
                        throw DiscordVoiceH264RTPError.incompleteFragment
                    }
                    protectedAccessUnit = completed
                }
            } catch DiscordVoiceNativeMediaPlaneError.receiveMediaTypeUnsupported {
                receiveCounters.droppedMediaTypeUnsupported &+= 1
                throw DiscordVoiceNativeMediaPlaneError.receiveMediaTypeUnsupported
            } catch {
                receiveCounters.droppedMalformed &+= 1
                throw DiscordVoiceNativeMediaPlaneError.receivePacketMalformed
            }
        }
        guard let protectedAccessUnit else {
            receiveCounters.droppedMalformed &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receivePacketMalformed
        }
        guard let daveSession = await daveSessionProvider() else {
            receiveCounters.droppedDAVE &+= 1
            throw DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable
        }
        try requireCurrentReceive(receiveRevision)
        let decoded: Data
        do {
            decoded = try await daveSession.unprotect(
                Data(protectedAccessUnit), mediaType: .video, senderID: senderID
            )
            _ = try DiscordVoiceH264Packetizer.nalUnits(in: Array(decoded))
        } catch {
            receiveCounters.droppedDAVE &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receiveDAVEUnprotectFailed
        }
        try requireCurrentReceive(receiveRevision)
        receiveCounters.acceptedVideoAccessUnits &+= 1
        return decoded
    }

    /// Synthesizes one 20 ms concealment frame for a source whose packet was
    /// lost, using that source's own Opus decoder state
    /// (`Opus20msCodec.decodePacketLoss()`).
    ///
    /// The decoder lives here (see `audioDecoders`), so this entry point is
    /// what lets the portable jitter buffer implement the spec's PLC policy
    /// without ever holding a codec or a key.
    ///
    /// Fails closed with `.receiveSourceUnknown` when the source has no
    /// decoder — that is, when no packet from it has ever been authenticated
    /// on this generation. Concealment is synthesized audio, so it is
    /// available only as a continuation of a stream that already passed both
    /// AEAD and DAVE; it can never introduce a stream that did not.
    public func concealAudioLoss(ssrc: UInt32) async throws -> [Int16] {
        guard let installed = runtime else {
            receiveCounters.droppedNotInstalled &+= 1
            throw DiscordVoiceNativeMediaPlaneError.mediaNotInstalled
        }
        guard installed.daveReady else {
            receiveCounters.droppedNotInstalled &+= 1
            throw DiscordVoiceNativeMediaPlaneError.daveProtectionRequired
        }
        let receiveRevision = revision

        guard let decoder = audioDecoders[ssrc] else {
            receiveCounters.droppedSourceUnknown &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receiveSourceUnknown
        }

        let pcm: [Int16]
        do {
            pcm = try await decoder.decodePacketLoss()
        } catch {
            receiveCounters.droppedDecode &+= 1
            throw DiscordVoiceNativeMediaPlaneError.receiveDecodeFailed
        }
        try requireCurrentReceive(receiveRevision)

        receiveCounters.concealed &+= 1
        return pcm
    }

    /// Drops one source's decoder state. This is the eviction hook for the
    /// portable layer's idle-SSRC timeout (spec §3): the timing policy and its
    /// injectable clock live there, the decoder lifetime lives here, so a busy
    /// guild does not leak decoders. Returns whether a decoder was released.
    @discardableResult
    public func releaseAudioSource(ssrc: UInt32) -> Bool {
        audioDecoders.removeValue(forKey: ssrc) != nil
    }

    /// Redacted receive telemetry. Counts and one cardinality only — never an
    /// SSRC, a nonce, packet bytes, or PCM.
    public func receiveDiagnostics() -> ReceiveDiagnostics {
        ReceiveDiagnostics(
            accepted: receiveCounters.accepted,
            acceptedVideoAccessUnits: receiveCounters.acceptedVideoAccessUnits,
            concealed: receiveCounters.concealed,
            droppedNotInstalled: receiveCounters.droppedNotInstalled,
            droppedTransportAuthentication: receiveCounters.droppedTransportAuthentication,
            droppedDAVE: receiveCounters.droppedDAVE,
            droppedMalformed: receiveCounters.droppedMalformed,
            droppedMediaTypeUnsupported: receiveCounters.droppedMediaTypeUnsupported,
            droppedDecode: receiveCounters.droppedDecode,
            droppedInterrupted: receiveCounters.droppedInterrupted,
            droppedSourceUnknown: receiveCounters.droppedSourceUnknown,
            activeAudioSources: audioDecoders.count
        )
    }

    private func audioDecoder(for ssrc: UInt32) throws -> Opus20msCodec {
        if let existing = audioDecoders[ssrc] { return existing }
        let decoder = try makeOpus()
        audioDecoders[ssrc] = decoder
        return decoder
    }

    /// `requireCurrent` for the receive path: same check, same idiom, but the
    /// refusal is counted so "no audio, and counted" holds for interruption
    /// exactly as it does for every other receive failure.
    private func requireCurrentReceive(_ expectedRevision: UInt64) throws {
        do {
            try requireCurrent(expectedRevision, orThrow: .receiveInterrupted)
        } catch {
            receiveCounters.droppedInterrupted &+= 1
            throw error
        }
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
    /// source re-arms the one-shot announcement obligation, seeds a fresh
    /// 90 kHz video RTP clock, and advances the video-source generation so any
    /// `sendVideoFrame` still suspended on the superseded source fails closed
    /// with `.sendInterrupted` instead of emitting a frame under the old SSRC
    /// and codec. Audio sends in flight are deliberately untouched: they do
    /// not depend on the video source.
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
        guard codec == .h264 else {
            // The initial canary advertises H.264 only. Never map or guess a
            // codec that has not passed the exact live control-plane probe.
            throw DiscordVoiceNativeMediaPlaneError.videoSourceInvalid
        }
        let payloadType = try Self.rtpPayloadType(for: codec)
        let announcement = try allocation.announcement(activeRIDs: activeRIDs)
        // Every rejection above happens before the generation moves, so a
        // refused install cannot interrupt sends against the source that is
        // still legitimately installed.
        videoRevision &+= 1
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
    /// packets, then sends them through the retained UDP socket. This composes
    /// the same Phase 5 boundary as `sendAudioFrame` for `.video` media: the
    /// installed `NativeDAVESession.protect` with the video frame type and
    /// negotiated codec label, the 90 kHz `DiscordVoiceVideoRTPClock`, the
    /// negotiated H.264 RTP payload type through RFC 6184 single-NAL/FU-A
    /// packetization with the marker bit set only at the access-unit boundary,
    /// the shared
    /// `DiscordVoiceTransportEncryption` AEAD counter, and the retained
    /// datagram transport. Both the generation revision and the video-source
    /// generation are re-checked after every suspension, so neither a
    /// `reset()`/superseding `install(_:)` nor a superseding
    /// `installVideoSource(...)` can let a stale generation or an obsolete
    /// video SSRC and codec reach the socket.
    ///
    /// Fails closed, never falling back to unprotected media, when: no
    /// generation is installed, the installed generation never attested a
    /// ready DAVE session, no video source is installed, the frame is empty,
    /// the Opcode 12 announcement callback is missing or fails (Discord
    /// requires the announcement before video media — unlike Speaking there
    /// is no tolerated absent-callback path), DAVE protection fails, or the
    /// installation or the installed video source is superseded mid-send.
    ///
    /// Boundary honesty: callers must supply Annex-B H.264 access units already
    /// encoded by the platform codec. Camera/screen capture and VideoToolbox
    /// are separate platform boundaries; promotion still requires the observed
    /// Discord control-plane mapping and a witnessed live qualification.
    public func sendVideoFrame(encodedFrame: Data) async throws {
        guard let installed = runtime else {
            throw DiscordVoiceNativeMediaPlaneError.mediaNotInstalled
        }
        guard installed.daveReady else {
            throw DiscordVoiceNativeMediaPlaneError.daveProtectionRequired
        }
        guard let videoSource, videoClock != nil else {
            throw DiscordVoiceNativeMediaPlaneError.videoSourceNotInstalled
        }
        guard !encodedFrame.isEmpty,
              encodedFrame.count <= DiscordVoiceH264Packetizer.maximumAccessUnitBytes,
              (try? DiscordVoiceH264Packetizer.nalUnits(in: Array(encodedFrame))) != nil
        else {
            throw DiscordVoiceNativeMediaPlaneError.videoFrameInvalid
        }
        let sendRevision = revision
        // Reserved together with the tick below: this send is bound to the
        // video source installed right now, and every suspension point below
        // re-checks it so a superseding `installVideoSource(...)` cannot let
        // this frame reach the socket under the obsolete SSRC and codec.
        let sendVideoRevision = videoRevision

        // NOTE — deliberate divergence from the audio path, which reserves its
        // tick before the first `await`. A video frame's fragment count is a
        // function of the DAVE-PROTECTED size, which is not known until
        // `protect` returns, so the sequence run cannot be reserved up front.
        // The clock itself must also be read only at that later reservation
        // point: copying it here would let two actor-reentrant sends carry the
        // same pre-protection clock through their awaits and emit duplicate RTP
        // sequence numbers. What is given up is that run ORDER may not match
        // frame order if a caller drives overlapping sends — production drives
        // one frame at a time, as the audio path already assumes.
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
        // `runOnce` re-checks `revision` itself but knows nothing about video
        // sources, so the announcement suspension is wrapped for the video half.
        try await guarded(revision: sendRevision, videoRevision: sendVideoRevision) {
            try await runOnce(
                .videoAnnouncement,
                signal: boundAnnouncement,
                revision: sendRevision
            )
        }

        guard let daveSession = try await guarded(
            revision: sendRevision,
            videoRevision: sendVideoRevision,
            { await daveSessionProvider() }
        ) else {
            throw DiscordVoiceNativeMediaPlaneError.daveSessionUnavailable
        }

        // DAVE protection is applied to the raw encoded frame before it ever
        // becomes an RTP body; nothing downstream can substitute plaintext.
        let protectedFrame = try await guarded(
            revision: sendRevision,
            videoRevision: sendVideoRevision
        ) {
            try await daveSession.protect(
                encodedFrame,
                mediaType: .video,
                codec: videoSource.codec,
                ssrc: videoSource.ssrc
            )
        }

        // This read/update is one synchronous actor-isolated transaction after
        // the protected size is known. Every overlapping send therefore sees
        // the clock advanced by the prior reservation, even though both may
        // have entered this method before either DAVE call completed.
        guard var reservedClock = videoClock else {
            throw DiscordVoiceNativeMediaPlaneError.sendInterrupted
        }

        // RFC 6184 packetization runs after DAVE's codec-aware frame transform
        // and before transport AEAD. Single NAL units remain whole; oversized
        // units use FU-A, with one timestamp and the marker only on the final
        // packet of the access unit.
        //
        // Reserving through the clock overload keeps the run atomic: a frame
        // rejected for being empty or oversized consumes no sequence numbers.
        let fragments = try makeH264Packetizer().packetize(
            annexB: Array(protectedFrame),
            payloadType: videoSource.payloadType,
            ssrc: videoSource.ssrc,
            clock: &reservedClock
        )
        videoClock = reservedClock

        let rtpCodec = try DiscordVoiceRTPCodec()
        for fragment in fragments {
            let plaintextPacket = try rtpCodec.encode(fragment.header) + fragment.payload
            // Guarded PER FRAGMENT, not once per frame: a video source
            // installed midway through a multi-fragment frame must not let the
            // remaining fragments reach the wire under the obsolete SSRC,
            // which would also strand a partial frame at the receiver.
            let wirePacket = try await guarded(
                revision: sendRevision,
                videoRevision: sendVideoRevision
            ) {
                try await installed.transportEncryption.seal(plaintextPacket)
            }
            try await guarded(revision: sendRevision, videoRevision: sendVideoRevision) {
                try await sendTracked(wirePacket, through: installed.datagramTransport)
            }
        }
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
        // Decoder state belongs to the generation whose keys authenticated the
        // packets that built it; a new install must not continue a superseded
        // generation's stream. Counters deliberately survive — see
        // `ReceiveDiagnostics`.
        audioDecoders.removeAll(keepingCapacity: false)
        speakingGate = .pending
        videoSource = nil
        videoClock = nil
        videoAnnouncementGate = .pending
        videoRevision &+= 1
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

    /// Runs one suspending step and re-validates the generation on the way
    /// out, so the reserve-then-recheck invariant is carried by the call itself
    /// rather than by a `requireCurrent` the author had to remember to write.
    ///
    /// This exists because the manual form failed twice under review: the video
    /// send path shipped without a per-fragment check, and the announcement
    /// step needed one added by hand because `runOnce` knows nothing about
    /// video sources. A suspension that is not wrapped is now the visible
    /// exception rather than the invisible default.
    private func guarded<Value>(
        revision expectedRevision: UInt64,
        videoRevision expectedVideoRevision: UInt64? = nil,
        orThrow error: DiscordVoiceNativeMediaPlaneError = .sendInterrupted,
        _ step: () async throws -> Value
    ) async throws -> Value {
        let value = try await step()
        try requireCurrent(expectedRevision, orThrow: error)
        if let expectedVideoRevision {
            try requireCurrentVideoSource(expectedVideoRevision, orThrow: error)
        }
        return value
    }

    private func requireCurrent(
        _ expectedRevision: UInt64,
        orThrow error: DiscordVoiceNativeMediaPlaneError = .installationInterrupted
    ) throws {
        guard revision == expectedRevision, !Task.isCancelled else {
            throw error
        }
    }

    /// The video counterpart to `requireCurrent`: fails a video send closed
    /// when the video source it reserved has since been replaced. Kept
    /// separate from `revision` so replacing a video source never interrupts
    /// an audio send that is legitimately in flight.
    private func requireCurrentVideoSource(
        _ expectedVideoRevision: UInt64,
        orThrow error: DiscordVoiceNativeMediaPlaneError = .sendInterrupted
    ) throws {
        guard videoRevision == expectedVideoRevision else { throw error }
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
