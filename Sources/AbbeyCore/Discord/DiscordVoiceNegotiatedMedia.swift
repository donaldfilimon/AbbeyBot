import Foundation

public enum DiscordVoiceNegotiatedMediaError: Error, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    case invalidGeneration
    case invalidSSRC
    case invalidTransportKey
    case duplicateInstallation
    case staleInstallation
    case capabilityConsumed

    public var description: String {
        switch self {
        case .invalidGeneration:
            "Negotiated media generation is invalid"
        case .invalidSSRC:
            "Negotiated media source is invalid"
        case .invalidTransportKey:
            "Negotiated media transport key is invalid"
        case .duplicateInstallation:
            "Negotiated media generation is already installed"
        case .staleInstallation:
            "Negotiated media generation is obsolete"
        case .capabilityConsumed:
            "Negotiated media capability is no longer available"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["error": description], displayStyle: .enum)
    }
}

/// A one-shot, in-memory authority for constructing the media transport.
///
/// The controller and UI never receive this object. Its raw transport key is
/// private and can only be consumed by constructing the existing single-owner
/// encryption actor. The remaining fields use package access so the native
/// media target can compose the session without widening the public API.
public final class DiscordVoiceNegotiatedMediaCapability: @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    package let generation: UInt64
    package let ssrc: UInt32
    package let transportMode: DiscordVoiceTransportMode
    package let daveProtocolVersion: UInt16
    private var transportKey: [UInt8]?
    private let consumptionLock = NSLock()
    private var consumed = false

    package init(
        generation: UInt64,
        ssrc: UInt32,
        transportMode: DiscordVoiceTransportMode,
        transportKey: [UInt8],
        daveProtocolVersion: UInt16
    ) throws {
        guard generation > 0 else {
            throw DiscordVoiceNegotiatedMediaError.invalidGeneration
        }
        guard ssrc > 0 else {
            throw DiscordVoiceNegotiatedMediaError.invalidSSRC
        }
        guard transportKey.count == DiscordVoiceTransportEncryption.keyLength else {
            throw DiscordVoiceNegotiatedMediaError.invalidTransportKey
        }
        self.generation = generation
        self.ssrc = ssrc
        self.transportMode = transportMode
        self.transportKey = transportKey
        self.daveProtocolVersion = daveProtocolVersion
    }

    public func makeTransportEncryption(
        primitive: any DiscordVoiceAEADPrimitive
    ) throws -> DiscordVoiceTransportEncryption {
        consumptionLock.lock()
        guard !consumed, let transportKey else {
            consumptionLock.unlock()
            throw DiscordVoiceNegotiatedMediaError.capabilityConsumed
        }
        consumed = true
        self.transportKey = nil
        consumptionLock.unlock()
        return try DiscordVoiceTransportEncryption(
            mode: transportMode,
            key: transportKey,
            primitive: primitive
        )
    }

    public var description: String {
        "DiscordVoiceNegotiatedMediaCapability(<redacted>)"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["negotiatedMedia": "<redacted>"], displayStyle: .class)
    }
}

/// Session-owned destination for the Voice Gateway's negotiated media data.
/// Implementations must retain the high-water generation across `reset()` so
/// a late task cannot reinstall an obsolete key after teardown.
public protocol DiscordVoiceMediaPlane: Sendable {
    var aes256GCMAvailable: Bool { get }

    func install(
        _ capability: DiscordVoiceNegotiatedMediaCapability
    ) async throws -> DiscordVoiceMediaCapabilities

    func updateDAVEProtocolVersion(
        _ version: UInt16,
        generation: UInt64
    ) async throws -> DiscordVoiceMediaCapabilities

    func reset() async
}

public extension DiscordVoiceMediaPlane {
    func updateDAVEProtocolVersion(
        _ version: UInt16,
        generation: UInt64
    ) async throws -> DiscordVoiceMediaCapabilities {
        DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false)
    }
}

/// Redacted, in-memory generation gate shared by portable tests and native
/// media-plane implementations. Reset drops the capability but deliberately
/// retains the generation watermark.
public actor DiscordVoiceNegotiatedMediaStore: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public struct Snapshot: Equatable, Sendable, CustomStringConvertible {
        public let isInstalled: Bool

        public var description: String {
            "DiscordVoiceNegotiatedMediaStore.Snapshot(isInstalled: \(isInstalled))"
        }
    }

    private var isInstalled = false
    private var highestGeneration: UInt64?

    public init() {}

    public func install(_ capability: DiscordVoiceNegotiatedMediaCapability) throws {
        if let highestGeneration {
            if capability.generation == highestGeneration {
                throw DiscordVoiceNegotiatedMediaError.duplicateInstallation
            }
            if capability.generation < highestGeneration {
                throw DiscordVoiceNegotiatedMediaError.staleInstallation
            }
        }
        highestGeneration = capability.generation
        isInstalled = true
    }

    public func reset() {
        isInstalled = false
    }

    public func snapshot() -> Snapshot {
        Snapshot(isInstalled: isInstalled)
    }

    public nonisolated var description: String {
        "DiscordVoiceNegotiatedMediaStore(<redacted>)"
    }

    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: ["negotiatedMedia": "<redacted>"], displayStyle: .class)
    }
}

/// Compatibility plane for portable callers that already provide a capability
/// attestation. It still enforces the one-shot generation boundary and retains
/// the negotiated object only inside the Gateway-owned plane.
actor DiscordVoiceAttestedMediaPlane: DiscordVoiceMediaPlane {
    nonisolated let aes256GCMAvailable: Bool

    private let attestation: DiscordVoiceMediaCapabilityAttestation
    private let store = DiscordVoiceNegotiatedMediaStore()
    private var activeGeneration: UInt64?
    private var activeMode: DiscordVoiceTransportMode?

    init(attestation: DiscordVoiceMediaCapabilityAttestation) {
        self.attestation = attestation
        self.aes256GCMAvailable = attestation.aes256GCMAvailable
    }

    func install(
        _ capability: DiscordVoiceNegotiatedMediaCapability
    ) async throws -> DiscordVoiceMediaCapabilities {
        try await store.install(capability)
        do {
            let result = try await attestation.attest(
                transportMode: capability.transportMode,
                daveProtocolVersion: Int(capability.daveProtocolVersion)
            )
            activeGeneration = capability.generation
            activeMode = capability.transportMode
            return result
        } catch {
            await store.reset()
            throw error
        }
    }


    func updateDAVEProtocolVersion(
        _ version: UInt16,
        generation: UInt64
    ) async throws -> DiscordVoiceMediaCapabilities {
        guard activeGeneration == generation, let activeMode else {
            throw DiscordVoiceNegotiatedMediaError.staleInstallation
        }
        if version == 0 {
            await store.reset()
            activeGeneration = nil
            self.activeMode = nil
            return DiscordVoiceMediaCapabilities(dave: false, aead: false, opus: false)
        }
        return try await attestation.attest(
            transportMode: activeMode,
            daveProtocolVersion: Int(version)
        )
    }

    func reset() async {
        await store.reset()
        activeGeneration = nil
        activeMode = nil
    }
}
