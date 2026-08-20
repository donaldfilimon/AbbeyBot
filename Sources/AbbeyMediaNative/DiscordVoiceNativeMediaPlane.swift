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

    private var highestGeneration: UInt64?
    private var revision: UInt64 = 0
    private var runtime: InstalledRuntime?
    private var clock: DiscordVoiceRTPClock?
    private var speakingSignal: (@Sendable () async throws -> Void)?
    private var hasSentSpeakingForInstalledRuntime = false

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
            hasSentSpeakingForInstalledRuntime = false
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
        let mustSendSpeaking = !hasSentSpeakingForInstalledRuntime
        if mustSendSpeaking {
            hasSentSpeakingForInstalledRuntime = true
        }

        // If this call owns Speaking and its own send later fails, no other
        // call re-attempts Speaking for this generation. Production callers
        // are expected to drive one send at a time from a single capture
        // loop, so this is a documented ordering caveat for out-of-order
        // concurrent failures, not a gap in the sequential case this Phase 5
        // slice proves.
        if mustSendSpeaking, let speakingSignal {
            do {
                try await speakingSignal()
            } catch {
                throw DiscordVoiceNativeMediaPlaneError.speakingSignalFailed
            }
            try requireCurrent(sendRevision, orThrow: .sendInterrupted)
        }

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

        try await installed.datagramTransport.sendProtectedPacket(wirePacket)
    }

    /// Drops every object that can retain the transport key while preserving
    /// the generation high-water mark against late installation tasks.
    public func reset() async {
        revision &+= 1
        clearRuntime()
        await generationStore.reset()
    }

    private func clearRuntime() {
        runtime = nil
        clock = nil
        hasSentSpeakingForInstalledRuntime = false
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
