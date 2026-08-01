import AbbeyCore
import Testing
@testable import AbbeyMediaNative

@Suite("Native Discord Voice AEAD adapter")
struct DiscordVoiceAEADAdapterTests {
    @Test("portable RTPSIZE transport round trips and rejects tampering with real XChaCha")
    func portableTransportIntegration() async throws {
        let primitive = try NativeDiscordVoiceAEADPrimitive(
            mode: .aeadXChaCha20Poly1305RTPSIZE
        )
        let key = Array(0..<UInt8(32))
        let sender = try DiscordVoiceTransportEncryption(
            mode: .aeadXChaCha20Poly1305RTPSIZE,
            key: key,
            primitive: primitive,
            initialSendCounter: 0x0102_0304
        )
        let receiver = try DiscordVoiceTransportEncryption(
            mode: .aeadXChaCha20Poly1305RTPSIZE,
            key: key,
            primitive: primitive
        )
        let header = try DiscordVoiceRTPHeader(
            sequence: 7,
            timestamp: 960,
            ssrc: 0xa0b0_c0d0
        )
        let plaintext = try DiscordVoiceRTPCodec().encode(header) + [0x10, 0x20, 0x30, 0x40]
        let protected = try await sender.seal(plaintext)
        let headerLength = try DiscordVoiceRTPCodec().unencryptedHeaderLength(in: protected)

        var tampered = protected
        tampered[headerLength] ^= 0x80
        do {
            _ = try await receiver.open(tampered)
            Issue.record("Expected authenticated native open to reject the tampered packet")
        } catch let error as DiscordVoiceTransportEncryptionError {
            #expect(error == .authenticationFailed)
        }

        #expect(try await receiver.open(protected) == plaintext)
        #expect(Array(protected.suffix(4)) == [0x01, 0x02, 0x03, 0x04])
    }

    @Test("adapter reuses one native context and rejects a changed key with a redacted error")
    func cachedContextRejectsChangedKey() async throws {
        let primitive = try NativeDiscordVoiceAEADPrimitive(
            mode: .aeadXChaCha20Poly1305RTPSIZE
        )
        let key = Array(0..<UInt8(32))
        let firstNonce = [UInt8](repeating: 0, count: 24)
        let secondNonce = [UInt8(0), 0, 0, 1] + [UInt8](repeating: 0, count: 20)

        let first = try await primitive.seal(
            plaintext: [1, 2, 3],
            key: key,
            nonce: firstNonce,
            authenticating: [4, 5]
        )
        let second = try await primitive.seal(
            plaintext: [1, 2, 3],
            key: key,
            nonce: secondNonce,
            authenticating: [4, 5]
        )
        #expect(first != second)

        var changedKey = key
        changedKey[0] ^= 0xff
        do {
            _ = try await primitive.seal(
                plaintext: [1],
                key: changedKey,
                nonce: firstNonce,
                authenticating: []
            )
            Issue.record("Expected a changed key to be rejected")
        } catch let error as NativeMediaError {
            #expect(error == .keyMismatch)
            #expect(error.localizedDescription == "The AEAD key does not match the initialized native context.")
            #expect(!error.localizedDescription.contains(String(changedKey[0])))
        }
    }
}
