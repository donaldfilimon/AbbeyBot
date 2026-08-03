import CSodium
import Foundation

public enum NativeAEADMode: String, Sendable {
    case xchacha20Poly1305
    case aes256GCM

    public var nonceLength: Int {
        switch self {
        case .xchacha20Poly1305: 24
        case .aes256GCM: 12
        }
    }

    public var keyLength: Int { 32 }
    public var tagLength: Int { 16 }
}

public struct NativeSealedPacket: Equatable, Sendable {
    public let ciphertext: Data

    public init(ciphertext: Data) {
        self.ciphertext = ciphertext
    }
}

/// Non-Sendable storage whose raw key pointer never leaves this module.
private final class SodiumKeyStorage {
    private let pointer: UnsafeMutablePointer<UInt8>
    let count: Int

    init(_ bytes: [UInt8]) {
        count = bytes.count
        pointer = .allocate(capacity: count)
        bytes.withUnsafeBufferPointer { buffer in
            pointer.initialize(from: buffer.baseAddress!, count: count)
        }
    }

    func withUnsafeBytes<Result>(_ body: (UnsafePointer<UInt8>) throws -> Result) rethrows -> Result {
        try body(UnsafePointer(pointer))
    }

    func matches(_ candidate: [UInt8]) -> Bool {
        guard candidate.count == count else { return false }
        return candidate.withUnsafeBufferPointer { buffer in
            sodium_memcmp(pointer, buffer.baseAddress!, count) == 0
        }
    }

    deinit {
        sodium_memzero(pointer, count)
        pointer.deinitialize(count: count)
        pointer.deallocate()
    }
}

/// Actor-owned AEAD key and mode with an exact caller-supplied nonce per operation.
///
/// This type deliberately has no counter state and assigns no meaning to nonce bytes. Discord
/// packet modes, including RTPSIZE's first-four-byte counter layout, belong to the caller.
public actor NativeAEAD {
    private let mode: NativeAEADMode
    private let key: SodiumKeyStorage

    public init(mode: NativeAEADMode, key: [UInt8]) throws {
        guard sodium_init() >= 0 else {
            throw NativeMediaError.initializationFailed(component: "libsodium")
        }
        guard key.count == mode.keyLength else {
            throw NativeMediaError.invalidKeyLength(expected: mode.keyLength, actual: key.count)
        }
        guard Self.isAvailable(mode) else {
            throw NativeMediaError.unavailable(component: mode.rawValue)
        }
        self.mode = mode
        self.key = SodiumKeyStorage(key)
    }

    public nonisolated static func isAvailable(_ mode: NativeAEADMode) -> Bool {
        guard sodium_init() >= 0 else { return false }
        switch mode {
        case .xchacha20Poly1305:
            return crypto_aead_xchacha20poly1305_ietf_keybytes() == 32
                && crypto_aead_xchacha20poly1305_ietf_npubbytes() == 24
                && crypto_aead_xchacha20poly1305_ietf_abytes() == 16
        case .aes256GCM:
            return crypto_aead_aes256gcm_is_available() == 1
                && crypto_aead_aes256gcm_keybytes() == 32
                && crypto_aead_aes256gcm_npubbytes() == 12
                && crypto_aead_aes256gcm_abytes() == 16
        }
    }

    /// Constant-time comparison against the zeroized native key storage.
    /// The candidate is never retained and no key bytes are exposed.
    public func matchesKey(_ candidate: [UInt8]) -> Bool {
        key.matches(candidate)
    }

    public func seal(
        _ plaintext: Data,
        nonce: [UInt8],
        authenticating additionalData: Data = Data()
    ) throws -> NativeSealedPacket {
        try validate(nonce: nonce)
        return NativeSealedPacket(ciphertext: try crypt(
            decrypting: false,
            input: plaintext,
            additionalData: additionalData,
            nonce: nonce
        ))
    }

    public func open(
        _ packet: NativeSealedPacket,
        nonce: [UInt8],
        authenticating additionalData: Data = Data()
    ) throws -> Data {
        try validate(nonce: nonce)
        guard packet.ciphertext.count >= mode.tagLength else {
            throw NativeMediaError.authenticationFailed
        }
        return try crypt(
            decrypting: true,
            input: packet.ciphertext,
            additionalData: additionalData,
            nonce: nonce
        )
    }

    private func validate(nonce: [UInt8]) throws {
        guard nonce.count == mode.nonceLength else {
            throw NativeMediaError.invalidNonceLength(expected: mode.nonceLength, actual: nonce.count)
        }
    }

    private func crypt(
        decrypting: Bool,
        input: Data,
        additionalData: Data,
        nonce: [UInt8]
    ) throws -> Data {
        let outputCapacity = decrypting ? input.count - mode.tagLength : input.count + mode.tagLength
        // libsodium imports these parameters as nonnull even when the corresponding length is zero.
        // Keep one inaccessible sentinel byte for zero-length buffers and always pass a real pointer.
        var output = Data(count: max(1, outputCapacity))
        let inputStorage = input.isEmpty ? [UInt8(0)] : Array(input)
        let additionalStorage = additionalData.isEmpty ? [UInt8(0)] : Array(additionalData)
        var outputLength: UInt64 = 0

        let result: Int32 = output.withUnsafeMutableBytes { outputBytes in
            inputStorage.withUnsafeBytes { inputBytes in
                additionalStorage.withUnsafeBytes { additionalBytes in
                    nonce.withUnsafeBytes { nonceBytes in
                        key.withUnsafeBytes { keyPointer in
                            let outputPointer = outputBytes.bindMemory(to: UInt8.self).baseAddress!
                            let inputPointer = inputBytes.bindMemory(to: UInt8.self).baseAddress!
                            let additionalPointer = additionalBytes.bindMemory(to: UInt8.self).baseAddress!
                            let noncePointer = nonceBytes.bindMemory(to: UInt8.self).baseAddress!

                            switch (mode, decrypting) {
                            case (.xchacha20Poly1305, false):
                                return crypto_aead_xchacha20poly1305_ietf_encrypt(
                                    outputPointer, &outputLength,
                                    inputPointer, UInt64(input.count),
                                    additionalPointer, UInt64(additionalData.count),
                                    nil, noncePointer, keyPointer
                                )
                            case (.xchacha20Poly1305, true):
                                return crypto_aead_xchacha20poly1305_ietf_decrypt(
                                    outputPointer, &outputLength, nil,
                                    inputPointer, UInt64(input.count),
                                    additionalPointer, UInt64(additionalData.count),
                                    noncePointer, keyPointer
                                )
                            case (.aes256GCM, false):
                                return crypto_aead_aes256gcm_encrypt(
                                    outputPointer, &outputLength,
                                    inputPointer, UInt64(input.count),
                                    additionalPointer, UInt64(additionalData.count),
                                    nil, noncePointer, keyPointer
                                )
                            case (.aes256GCM, true):
                                return crypto_aead_aes256gcm_decrypt(
                                    outputPointer, &outputLength, nil,
                                    inputPointer, UInt64(input.count),
                                    additionalPointer, UInt64(additionalData.count),
                                    noncePointer, keyPointer
                                )
                            }
                        }
                    }
                }
            }
        }

        guard result == 0 else {
            if decrypting { throw NativeMediaError.authenticationFailed }
            throw NativeMediaError.initializationFailed(component: mode.rawValue)
        }
        if Int(outputLength) < output.count {
            output.removeSubrange(Int(outputLength)..<output.count)
        }
        return output
    }
}
