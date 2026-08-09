import AbbeyCore

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

    public var description: String {
        switch self {
        case .installationInterrupted:
            "Native Discord media installation was interrupted"
        case .nativeComponentsUnavailable:
            "Native Discord media components are unavailable"
        case .daveSessionUnavailable:
            "Native DAVE media state is unavailable"
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

    private struct InstalledRuntime: Sendable {
        let transportEncryption: DiscordVoiceTransportEncryption
        let opus: Opus20msCodec
        let datagramTransport: any DiscordVoiceMediaDatagramTransport
        let ssrc: UInt32
    }

    public nonisolated let aes256GCMAvailable: Bool

    private let generationStore = DiscordVoiceNegotiatedMediaStore()
    private let daveSessionProvider: DAVESessionProvider
    private let datagramTransport: any DiscordVoiceMediaDatagramTransport
    private let makeAEADPrimitive: AEADPrimitiveFactory
    private let makeOpus: OpusFactory

    private var highestGeneration: UInt64?
    private var revision: UInt64 = 0
    private var runtime: InstalledRuntime?

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
    }

    init(
        aes256GCMAvailable: Bool,
        daveSessionProvider: @escaping DAVESessionProvider,
        datagramTransport: any DiscordVoiceMediaDatagramTransport,
        makeAEADPrimitive: @escaping AEADPrimitiveFactory = {
            try NativeDiscordVoiceAEADPrimitive(mode: $0)
        },
        makeOpus: @escaping OpusFactory = { try Opus20msCodec() }
    ) {
        self.aes256GCMAvailable = aes256GCMAvailable
        self.daveSessionProvider = daveSessionProvider
        self.datagramTransport = datagramTransport
        self.makeAEADPrimitive = makeAEADPrimitive
        self.makeOpus = makeOpus
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
        runtime = nil

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
                ssrc: capability.ssrc
            )
            return DiscordVoiceMediaCapabilities(
                dave: daveAvailable,
                aead: true,
                opus: true
            )
        } catch let error as DiscordVoiceNegotiatedMediaError {
            if revision == installationRevision {
                runtime = nil
                await generationStore.reset()
            }
            throw error
        } catch let error as DiscordVoiceNativeMediaPlaneError {
            if revision == installationRevision {
                runtime = nil
                await generationStore.reset()
            }
            throw error
        } catch {
            if revision == installationRevision {
                runtime = nil
                await generationStore.reset()
            }
            throw DiscordVoiceNativeMediaPlaneError.nativeComponentsUnavailable
        }
    }

    /// Re-attests the adapter's current DAVE session after an executed Voice
    /// Gateway transition. The media plane never caches the returned native
    /// session, so subsequent packet work cannot retain an obsolete epoch.
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
            runtime = installedRuntime
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

    /// Drops every object that can retain the transport key while preserving
    /// the generation high-water mark against late installation tasks.
    public func reset() async {
        revision &+= 1
        runtime = nil
        await generationStore.reset()
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

    private func requireCurrent(_ expectedRevision: UInt64) throws {
        guard revision == expectedRevision, !Task.isCancelled else {
            throw DiscordVoiceNativeMediaPlaneError.installationInterrupted
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
