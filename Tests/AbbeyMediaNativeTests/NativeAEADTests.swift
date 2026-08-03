import Foundation
import Testing
@testable import AbbeyMediaNative

@Suite("Native AEAD")
struct NativeAEADTests {
    @Test("libsodium XChaCha20-Poly1305 official vector uses the exact caller nonce")
    func xchachaKnownAnswer() async throws {
        let key = try bytes("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        let nonce = try bytes("07000000404142434445464748494a4b4c4d4e4f50515253")
        let aad = Data(try bytes("50515253c0c1c2c3c4c5c6c7"))
        let message = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let expected = Data(try bytes(
            "f8ebea4875044066fc162a0604e171feecfb3d20425248563bcfd5a155dcc47b" +
            "bda70b86e5ab9b55002bd1274c02db35321acd7af8b2e2d25015e136b7679458" +
            "e9f43243bf719d639badb5feac03f80a19a96ef10cb1d15333a837b90946ba38" +
            "54ee74da3f2585efc7e1e170e17e15e563e77601f4f85cafa8e5877614e143e68420"
        ))
        let aead = try NativeAEAD(mode: .xchacha20Poly1305, key: key)

        let sealed = try await aead.seal(message, nonce: nonce, authenticating: aad)
        #expect(sealed.ciphertext == expected)
        #expect(try await aead.open(sealed, nonce: nonce, authenticating: aad) == message)
    }

    @Test("libsodium AES-256-GCM official vector when hardware supports it")
    func aesKnownAnswer() async throws {
        guard NativeAEAD.isAvailable(.aes256GCM) else { return }
        let key = try bytes("b52c505a37d78eda5dd34f20c22540ea1b58963cf8e5bf8ffa85f9f2492505b4")
        let nonce = try bytes("516c33929df5a3284ff463d7")
        let aead = try NativeAEAD(mode: .aes256GCM, key: key)
        let sealed = try await aead.seal(Data(), nonce: nonce)
        #expect(sealed.ciphertext == Data(try bytes("bdc1ac884d332457a1d2664f168c76f0")))
        #expect(try await aead.open(sealed, nonce: nonce).isEmpty)
    }

    @Test("different caller RTPSIZE counter bytes produce distinct valid ciphertext")
    func callerSuppliedCounterBytes() async throws {
        let aead = try NativeAEAD(
            mode: .xchacha20Poly1305,
            key: [UInt8](repeating: 7, count: 32)
        )
        let message = Data([1, 2, 3, 4])
        let aad = Data([5, 6, 7])
        let firstNonce = [UInt8](repeating: 0, count: 24)
        let secondNonce = [UInt8(0), 0, 0, 1] + [UInt8](repeating: 0, count: 20)

        let first = try await aead.seal(message, nonce: firstNonce, authenticating: aad)
        let second = try await aead.seal(message, nonce: secondNonce, authenticating: aad)

        #expect(first.ciphertext != second.ciphertext)
        #expect(try await aead.open(first, nonce: firstNonce, authenticating: aad) == message)
        #expect(try await aead.open(second, nonce: secondNonce, authenticating: aad) == message)
    }

    @Test("invalid nonce lengths and authentication failures are closed failures")
    func safetyFailures() async throws {
        let aead = try NativeAEAD(
            mode: .xchacha20Poly1305,
            key: [UInt8](repeating: 7, count: 32)
        )
        await #expect(throws: NativeMediaError.invalidNonceLength(expected: 24, actual: 23)) {
            try await aead.seal(Data([1]), nonce: [UInt8](repeating: 0, count: 23))
        }

        let nonce = [UInt8](repeating: 9, count: 24)
        let sealed = try await aead.seal(Data([1, 2, 3]), nonce: nonce)
        var tampered = sealed.ciphertext
        tampered[tampered.startIndex] ^= 1
        await #expect(throws: NativeMediaError.authenticationFailed) {
            try await aead.open(.init(ciphertext: tampered), nonce: nonce)
        }
    }
}

private enum HexError: Error { case invalid }

private func bytes(_ hex: String) throws -> [UInt8] {
    guard hex.count.isMultiple(of: 2) else { throw HexError.invalid }
    var result: [UInt8] = []
    result.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let end = hex.index(index, offsetBy: 2)
        guard let value = UInt8(hex[index..<end], radix: 16) else { throw HexError.invalid }
        result.append(value)
        index = end
    }
    return result
}
