import AbbeyCore
import Foundation

/// Audited native AEAD adapter for AbbeyCore's portable Discord Voice RTPSIZE layer.
///
/// Counter layout, nonce construction, replay protection, and RTP framing remain in AbbeyCore.
/// This adapter forwards the exact key, nonce, payload, and associated-data bytes it receives.
public actor NativeDiscordVoiceAEADPrimitive: DiscordVoiceAEADPrimitive {
    public nonisolated let mode: DiscordVoiceTransportMode
    public nonisolated let authenticationTagLength = 16
    private var cachedAEAD: NativeAEAD?

    public init(mode: DiscordVoiceTransportMode) throws {
        guard Self.isAvailable(mode) else {
            throw NativeMediaError.unavailable(component: mode.rawValue)
        }
        self.mode = mode
    }

    public static func isAvailable(_ mode: DiscordVoiceTransportMode) -> Bool {
        NativeAEAD.isAvailable(nativeMode(for: mode))
    }

    public func seal(
        plaintext: [UInt8],
        key: [UInt8],
        nonce: [UInt8],
        authenticating associatedData: [UInt8]
    ) async throws -> [UInt8] {
        let aead = try await aead(for: key)
        let packet = try await aead.seal(
            Data(plaintext),
            nonce: nonce,
            authenticating: Data(associatedData)
        )
        return Array(packet.ciphertext)
    }

    public func open(
        ciphertextAndTag: [UInt8],
        key: [UInt8],
        nonce: [UInt8],
        authenticating associatedData: [UInt8]
    ) async throws -> [UInt8] {
        let aead = try await aead(for: key)
        let plaintext = try await aead.open(
            NativeSealedPacket(ciphertext: Data(ciphertextAndTag)),
            nonce: nonce,
            authenticating: Data(associatedData)
        )
        return Array(plaintext)
    }

    private func aead(for key: [UInt8]) async throws -> NativeAEAD {
        if let cachedAEAD {
            guard await cachedAEAD.matchesKey(key) else {
                throw NativeMediaError.keyMismatch
            }
            return cachedAEAD
        }

        // No suspension occurs before assignment, so actor reentrancy cannot initialize two keys.
        let initialized = try NativeAEAD(mode: Self.nativeMode(for: mode), key: key)
        cachedAEAD = initialized
        return initialized
    }

    private static func nativeMode(for mode: DiscordVoiceTransportMode) -> NativeAEADMode {
        switch mode {
        case .aeadXChaCha20Poly1305RTPSIZE:
            .xchacha20Poly1305
        case .aeadAES256GCMRTPSIZE:
            .aes256GCM
        }
    }
}
