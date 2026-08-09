import Testing
@testable import AbbeyCore

@Suite("Discord Voice negotiated-media handoff")
struct DiscordVoiceNegotiatedMediaTests {
    private let key = Array(40..<UInt8(72))

    @Test("capability validates generation, source, and transport-key length")
    func constructionValidation() throws {
        #expect(throws: DiscordVoiceNegotiatedMediaError.invalidGeneration) {
            _ = try makeCapability(generation: 0)
        }
        #expect(throws: DiscordVoiceNegotiatedMediaError.invalidSSRC) {
            _ = try makeCapability(ssrc: 0)
        }
        #expect(throws: DiscordVoiceNegotiatedMediaError.invalidTransportKey) {
            _ = try makeCapability(key: Array(repeating: 1, count: 31))
        }
        #expect(throws: DiscordVoiceNegotiatedMediaError.invalidTransportKey) {
            _ = try makeCapability(key: Array(repeating: 1, count: 33))
        }

        let capability = try makeCapability(daveProtocolVersion: 0)
        #expect(capability.generation == 1)
        #expect(capability.daveProtocolVersion == 0)
    }

    @Test("diagnostics redact key and source correlation data")
    func diagnosticRedaction() throws {
        let capability = try makeCapability(
            generation: 9_876_543,
            ssrc: 3_456_789,
            daveProtocolVersion: 321
        )
        let rendered = [
            capability.description,
            capability.debugDescription,
            String(reflecting: capability),
            String(describing: capability.customMirror),
            String(describing: Mirror(reflecting: capability)),
            dumpString(capability),
        ].joined(separator: "\n")

        #expect(rendered.contains("<redacted>"))
        #expect(!rendered.contains("9876543"))
        #expect(!rendered.contains("3456789"))
        #expect(!rendered.contains("321"))
        #expect(!rendered.contains("40, 41, 42"))

        let error = DiscordVoiceNegotiatedMediaError.invalidTransportKey
        let errorText = "\(error)\n\(String(reflecting: error))\n\(dumpString(error))"
        #expect(!errorText.contains("40, 41, 42"))
    }

    @Test("transport-key authority is consumable exactly once")
    func oneShotConsumption() throws {
        let capability = try makeCapability()
        let primitive = NegotiatedMediaTestAEAD()
        _ = try capability.makeTransportEncryption(primitive: primitive)
        #expect(throws: DiscordVoiceNegotiatedMediaError.capabilityConsumed) {
            _ = try capability.makeTransportEncryption(primitive: primitive)
        }
    }

    @Test("generation watermark rejects duplicate and stale key installation after reset")
    func generationWatermark() async throws {
        let store = DiscordVoiceNegotiatedMediaStore()
        try await store.install(makeCapability(generation: 10))
        #expect(await store.snapshot().isInstalled)

        do {
            try await store.install(makeCapability(generation: 10))
            Issue.record("Expected duplicate generation to fail")
        } catch let error as DiscordVoiceNegotiatedMediaError {
            #expect(error == .duplicateInstallation)
        }

        await store.reset()
        #expect(!(await store.snapshot().isInstalled))
        do {
            try await store.install(makeCapability(generation: 10))
            Issue.record("Expected reset generation to remain retired")
        } catch let error as DiscordVoiceNegotiatedMediaError {
            #expect(error == .duplicateInstallation)
        }
        do {
            try await store.install(makeCapability(generation: 9))
            Issue.record("Expected older generation to fail")
        } catch let error as DiscordVoiceNegotiatedMediaError {
            #expect(error == .staleInstallation)
        }

        try await store.install(makeCapability(generation: 11))
        #expect(await store.snapshot().isInstalled)
        let rendered = "\(await store.snapshot())\n\(store)\n\(dumpString(store))"
        #expect(!rendered.contains("3456789"))
        #expect(!rendered.contains("40, 41, 42"))
    }

    private func makeCapability(
        generation: UInt64 = 1,
        ssrc: UInt32 = 3_456_789,
        key: [UInt8]? = nil,
        daveProtocolVersion: UInt16 = 1
    ) throws -> DiscordVoiceNegotiatedMediaCapability {
        try DiscordVoiceNegotiatedMediaCapability(
            generation: generation,
            ssrc: ssrc,
            transportMode: .aeadXChaCha20Poly1305RTPSIZE,
            transportKey: key ?? self.key,
            daveProtocolVersion: daveProtocolVersion
        )
    }

    private func dumpString<T>(_ value: T) -> String {
        var output = ""
        dump(value, to: &output)
        return output
    }
}

private struct NegotiatedMediaTestAEAD: DiscordVoiceAEADPrimitive {
    let mode = DiscordVoiceTransportMode.aeadXChaCha20Poly1305RTPSIZE
    let authenticationTagLength = DiscordVoiceTransportEncryption.authenticationTagLength

    func seal(
        plaintext: [UInt8],
        key: [UInt8],
        nonce: [UInt8],
        authenticating associatedData: [UInt8]
    ) async throws -> [UInt8] {
        plaintext + Array(repeating: 0, count: authenticationTagLength)
    }

    func open(
        ciphertextAndTag: [UInt8],
        key: [UInt8],
        nonce: [UInt8],
        authenticating associatedData: [UInt8]
    ) async throws -> [UInt8] {
        Array(ciphertextAndTag.dropLast(authenticationTagLength))
    }
}
