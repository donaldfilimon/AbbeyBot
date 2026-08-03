import Testing
@testable import AbbeyCore

@Suite("Discord Voice RTPSIZE transport encryption")
struct DiscordVoiceTransportEncryptionTests {
    private let key = Array(0..<UInt8(32))

    @Test("Negotiation prefers hardware AES and falls back to mandatory XChaCha")
    func modeNegotiation() throws {
        let both = DiscordVoiceTransportMode.allCases.map(\.rawValue)
        #expect(
            try DiscordVoiceTransportMode.negotiate(
                advertisedModes: both,
                aes256GCMAvailable: true
            ) == .aeadAES256GCMRTPSIZE
        )
        #expect(
            try DiscordVoiceTransportMode.negotiate(
                advertisedModes: both,
                aes256GCMAvailable: false
            ) == .aeadXChaCha20Poly1305RTPSIZE
        )
        #expect(
            try DiscordVoiceTransportMode.negotiate(
                advertisedModes: [DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE.rawValue],
                aes256GCMAvailable: true
            ) == .aeadXChaCha20Poly1305RTPSIZE
        )

        do {
            _ = try DiscordVoiceTransportMode.negotiate(
                advertisedModes: [DiscordVoiceTransportMode.aeadAES256GCMRTPSIZE.rawValue],
                aes256GCMAvailable: false
            )
            Issue.record("Expected negotiation to fail without a usable advertised mode")
        } catch let error as DiscordVoiceTransportEncryptionError {
            #expect(error == .noCompatibleMode)
        }
    }

    @Test("Construction binds the negotiated mode, 32-byte key, and 16-byte tag")
    func constructionValidation() throws {
        let xchacha = RecordingFakeAEAD(mode: .aeadXChaCha20Poly1305RTPSIZE)
        do {
            _ = try DiscordVoiceTransportEncryption(
                mode: .aeadXChaCha20Poly1305RTPSIZE,
                key: Array(repeating: 0, count: 31),
                primitive: xchacha
            )
            Issue.record("Expected a short transport key to fail")
        } catch let error as DiscordVoiceTransportEncryptionError {
            #expect(error == .invalidKeyLength(expected: 32, actual: 31))
        }

        do {
            _ = try DiscordVoiceTransportEncryption(
                mode: .aeadAES256GCMRTPSIZE,
                key: key,
                primitive: xchacha
            )
            Issue.record("Expected a primitive for the wrong negotiated mode to fail")
        } catch let error as DiscordVoiceTransportEncryptionError {
            #expect(
                error == .primitiveModeMismatch(
                    expected: .aeadAES256GCMRTPSIZE,
                    actual: .aeadXChaCha20Poly1305RTPSIZE
                )
            )
        }

        let shortTag = RecordingFakeAEAD(
            mode: .aeadXChaCha20Poly1305RTPSIZE,
            authenticationTagLength: 8
        )
        do {
            _ = try DiscordVoiceTransportEncryption(
                mode: .aeadXChaCha20Poly1305RTPSIZE,
                key: key,
                primitive: shortTag
            )
            Issue.record("Expected a non-standard tag length to fail")
        } catch let error as DiscordVoiceTransportEncryptionError {
            #expect(error == .invalidAuthenticationTagLength(expected: 16, actual: 8))
        }
    }

    @Test(
        "Mode-specific nonce, full variable RTP header AAD, and suffix are exact",
        arguments: [
            DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE,
            .aeadAES256GCMRTPSIZE,
        ]
    )
    func exactFraming(mode: DiscordVoiceTransportMode) async throws {
        let primitive = RecordingFakeAEAD(mode: mode)
        let transport = try DiscordVoiceTransportEncryption(
            mode: mode,
            key: key,
            primitive: primitive,
            initialSendCounter: 0x0102_0304
        )
        let packet = try makePacket(
            ssrc: 0xa0b0_c0d0,
            payload: [0x10, 0x20, 0x30],
            csrcs: [0x1112_1314],
            extensionData: [0xde, 0xad, 0xbe, 0xef]
        )
        let headerLength = try DiscordVoiceRTPCodec().unencryptedHeaderLength(in: packet)

        let protected = try await transport.seal(packet)
        let calls = await primitive.sealCalls
        let call = try #require(calls.first)

        #expect(calls.count == 1)
        #expect(call.plaintext == [0x10, 0x20, 0x30])
        #expect(call.key == key)
        #expect(call.nonce == [0x01, 0x02, 0x03, 0x04] + Array(repeating: 0, count: mode.nonceLength - 4))
        #expect(call.associatedData == Array(packet[..<headerLength]))
        #expect(Array(protected[..<headerLength]) == Array(packet[..<headerLength]))
        #expect(Array(protected.suffix(4)) == [0x01, 0x02, 0x03, 0x04])
        #expect(try await transport.open(protected) == packet)
    }

    @Test("CSRC and extension bytes remain clear and round trip")
    func csrcAndExtensionRoundTrip() async throws {
        let primitive = RecordingFakeAEAD(mode: .aeadXChaCha20Poly1305RTPSIZE)
        let transport = try makeTransport(primitive: primitive)
        let packet = try makePacket(
            ssrc: 77,
            payload: [1, 2, 3, 4],
            csrcs: [8, 9],
            extensionData: [0x10, 0x20, 0x30, 0x40, 0, 0, 0, 0]
        )
        let headerLength = try DiscordVoiceRTPCodec().unencryptedHeaderLength(in: packet)

        let protected = try await transport.seal(packet)
        #expect(Array(protected[..<headerLength]) == Array(packet[..<headerLength]))
        #expect(try await transport.open(protected) == packet)
    }

    @Test("Authentication failure does not poison receive replay state")
    func tamperDoesNotPoisonReplay() async throws {
        let primitive = RecordingFakeAEAD(mode: .aeadXChaCha20Poly1305RTPSIZE)
        let sender = try makeTransport(primitive: primitive, initialCounter: 42)
        let receiver = try makeTransport(primitive: primitive)
        let plaintext = try makePacket(ssrc: 55, payload: [1, 2, 3])
        let protected = try await sender.seal(plaintext)
        let headerLength = try DiscordVoiceRTPCodec().unencryptedHeaderLength(in: protected)
        var tampered = protected
        tampered[headerLength] ^= 0xff

        await expectError(.authenticationFailed) {
            _ = try await receiver.open(tampered)
        }
        #expect(try await receiver.open(protected) == plaintext)
        await expectError(.duplicateNonce(ssrc: 55, nonce: 42)) {
            _ = try await receiver.open(protected)
        }
    }

    @Test("Replay counters are independent per SSRC")
    func replayIsPerSSRC() async throws {
        let primitive = RecordingFakeAEAD(mode: .aeadXChaCha20Poly1305RTPSIZE)
        let firstSender = try makeTransport(primitive: primitive, initialCounter: 7)
        let secondSender = try makeTransport(primitive: primitive, initialCounter: 7)
        let receiver = try makeTransport(primitive: primitive)
        let first = try await firstSender.seal(makePacket(ssrc: 100, payload: [1]))
        let second = try await secondSender.seal(makePacket(ssrc: 200, payload: [2]))

        _ = try await receiver.open(first)
        _ = try await receiver.open(second)
        await expectError(.duplicateNonce(ssrc: 100, nonce: 7)) {
            _ = try await receiver.open(first)
        }
        await expectError(.duplicateNonce(ssrc: 200, nonce: 7)) {
            _ = try await receiver.open(second)
        }
    }

    @Test("Receive window accepts bounded reordering and rejects duplicates and old nonces")
    func duplicateAndOldNonceRejection() async throws {
        let primitive = RecordingFakeAEAD(mode: .aeadXChaCha20Poly1305RTPSIZE)
        let receiver = try DiscordVoiceTransportEncryption(
            mode: .aeadXChaCha20Poly1305RTPSIZE,
            key: key,
            primitive: primitive,
            replayWindowSize: 4
        )
        let packet10 = try await sealedPacket(counter: 10, ssrc: 9, primitive: primitive)
        let packet13 = try await sealedPacket(counter: 13, ssrc: 9, primitive: primitive)
        let packet11 = try await sealedPacket(counter: 11, ssrc: 9, primitive: primitive)
        let packet9 = try await sealedPacket(counter: 9, ssrc: 9, primitive: primitive)

        _ = try await receiver.open(packet10)
        _ = try await receiver.open(packet13)
        _ = try await receiver.open(packet11)
        await expectError(.duplicateNonce(ssrc: 9, nonce: 11)) {
            _ = try await receiver.open(packet11)
        }
        await expectError(.nonceTooOld(ssrc: 9, nonce: 9)) {
            _ = try await receiver.open(packet9)
        }
    }

    @Test("Authenticated source tracking is bounded")
    func sourceCapacity() async throws {
        let primitive = RecordingFakeAEAD(mode: .aeadXChaCha20Poly1305RTPSIZE)
        let receiver = try DiscordVoiceTransportEncryption(
            mode: .aeadXChaCha20Poly1305RTPSIZE,
            key: key,
            primitive: primitive,
            sourceCapacity: 1
        )
        let first = try await sealedPacket(counter: 1, ssrc: 1, primitive: primitive)
        let second = try await sealedPacket(counter: 1, ssrc: 2, primitive: primitive)

        _ = try await receiver.open(first)
        await expectError(.sourceCapacityExceeded(1)) {
            _ = try await receiver.open(second)
        }
    }

    @Test("Final UInt32 counter is used once and never wraps")
    func counterExhaustion() async throws {
        let primitive = RecordingFakeAEAD(mode: .aeadXChaCha20Poly1305RTPSIZE)
        let transport = try makeTransport(primitive: primitive, initialCounter: .max)
        let packet = try makePacket(ssrc: 1, payload: [1])

        let finalPacket = try await transport.seal(packet)
        #expect(Array(finalPacket.suffix(4)) == [0xff, 0xff, 0xff, 0xff])
        #expect(await transport.nextSendCounter == nil)
        await expectError(.sendCounterExhausted) {
            _ = try await transport.seal(packet)
        }
        #expect(await primitive.sealCalls.count == 1)
    }

    @Test("Malformed protected bodies fail closed before native open")
    func malformedProtectedBody() async throws {
        let primitive = RecordingFakeAEAD(mode: .aeadXChaCha20Poly1305RTPSIZE)
        let receiver = try makeTransport(primitive: primitive)
        let header = try DiscordVoiceRTPCodec().encode(
            try DiscordVoiceRTPHeader(sequence: 1, timestamp: 2, ssrc: 3)
        )
        let malformed = header + Array(repeating: UInt8(0), count: 15) + [0, 0, 0, 1]

        await expectError(.packetMissingProtectedPayload) {
            _ = try await receiver.open(malformed)
        }
        #expect(await primitive.openCalls.isEmpty)
    }

    private func makeTransport(
        primitive: RecordingFakeAEAD,
        initialCounter: UInt32 = 0
    ) throws -> DiscordVoiceTransportEncryption {
        try DiscordVoiceTransportEncryption(
            mode: primitive.mode,
            key: key,
            primitive: primitive,
            initialSendCounter: initialCounter
        )
    }

    private func makePacket(
        ssrc: UInt32,
        payload: [UInt8],
        csrcs: [UInt32] = [],
        extensionData: [UInt8]? = nil
    ) throws -> [UInt8] {
        let headerExtension = try extensionData.map {
            try DiscordVoiceRTPHeaderExtension(profile: 0xbede, data: $0)
        }
        let header = try DiscordVoiceRTPHeader(
            sequence: 1,
            timestamp: 960,
            ssrc: ssrc,
            csrcs: csrcs,
            headerExtension: headerExtension
        )
        return try DiscordVoiceRTPCodec().encode(header) + payload
    }

    private func sealedPacket(
        counter: UInt32,
        ssrc: UInt32,
        primitive: RecordingFakeAEAD
    ) async throws -> [UInt8] {
        let sender = try makeTransport(primitive: primitive, initialCounter: counter)
        return try await sender.seal(makePacket(ssrc: ssrc, payload: [UInt8(truncatingIfNeeded: counter)]))
    }

    private func expectError(
        _ expected: DiscordVoiceTransportEncryptionError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as DiscordVoiceTransportEncryptionError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private actor RecordingFakeAEAD: DiscordVoiceAEADPrimitive {
    struct Call: Equatable, Sendable {
        let plaintext: [UInt8]
        let key: [UInt8]
        let nonce: [UInt8]
        let associatedData: [UInt8]
    }

    nonisolated let mode: DiscordVoiceTransportMode
    nonisolated let authenticationTagLength: Int
    private(set) var sealCalls: [Call] = []
    private(set) var openCalls: [Call] = []

    init(mode: DiscordVoiceTransportMode, authenticationTagLength: Int = 16) {
        self.mode = mode
        self.authenticationTagLength = authenticationTagLength
    }

    func seal(
        plaintext: [UInt8],
        key: [UInt8],
        nonce: [UInt8],
        authenticating associatedData: [UInt8]
    ) async throws -> [UInt8] {
        sealCalls.append(.init(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            associatedData: associatedData
        ))
        let ciphertext = transform(plaintext, key: key)
        return ciphertext + tag(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            associatedData: associatedData
        )
    }

    func open(
        ciphertextAndTag: [UInt8],
        key: [UInt8],
        nonce: [UInt8],
        authenticating associatedData: [UInt8]
    ) async throws -> [UInt8] {
        guard ciphertextAndTag.count >= authenticationTagLength else {
            throw FakeAEADError.authenticationFailed
        }
        let ciphertext = Array(ciphertextAndTag.dropLast(authenticationTagLength))
        let plaintext = transform(ciphertext, key: key)
        openCalls.append(.init(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            associatedData: associatedData
        ))
        guard Array(ciphertextAndTag.suffix(authenticationTagLength)) == tag(
            plaintext: plaintext,
            key: key,
            nonce: nonce,
            associatedData: associatedData
        ) else {
            throw FakeAEADError.authenticationFailed
        }
        return plaintext
    }

    private func transform(_ bytes: [UInt8], key: [UInt8]) -> [UInt8] {
        bytes.enumerated().map { index, byte in byte ^ key[index % key.count] ^ 0xa5 }
    }

    private func tag(
        plaintext: [UInt8],
        key: [UInt8],
        nonce: [UInt8],
        associatedData: [UInt8]
    ) -> [UInt8] {
        var state: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in plaintext + key + nonce + associatedData {
            state ^= UInt64(byte)
            state &*= 0x0000_0100_0000_01b3
        }
        return (0..<authenticationTagLength).map { index in
            UInt8(truncatingIfNeeded: state >> UInt64((index % 8) * 8)) ^ UInt8(index)
        }
    }
}

private enum FakeAEADError: Error {
    case authenticationFailed
}
