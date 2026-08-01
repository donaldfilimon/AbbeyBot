import Testing
@testable import AbbeyCore

@Suite("Discord voice Gateway handshake")
struct VoiceGatewayHandshakeTests {
    @Test("pairs state then server and emits credentials once")
    func stateThenServer() {
        var handshake = VoiceGatewayHandshake()
        let generation = handshake.begin(guildID: "guild", channelID: "channel", userID: "bot")

        let first = handshake.receive(
            .init(guildID: "guild", channelID: "channel", userID: "bot", sessionID: "session")
        )
        guard case .waiting(let waitingGeneration) = first else {
            Issue.record("Expected the voice-state event to wait for the server event")
            return
        }
        #expect(waitingGeneration == generation)

        let second = handshake.receive(
            .init(guildID: "guild", endpoint: "voice.example.test", token: "secret-token")
        )
        guard case .ready(let credentials) = second else {
            Issue.record("Expected paired events to emit credentials")
            return
        }
        #expect(credentials.guildID == "guild")
        #expect(credentials.channelID == "channel")
        #expect(credentials.userID == "bot")
        #expect(credentials.sessionID == "session")
        #expect(credentials.endpoint == "voice.example.test")
        #expect(credentials.token == "secret-token")
        #expect(credentials.generation == generation)

        let duplicate = handshake.receive(
            .init(guildID: "guild", endpoint: "voice.example.test", token: "secret-token")
        )
        guard case .ignored = duplicate else {
            Issue.record("Credentials must be emitted exactly once")
            return
        }
    }

    @Test("pairs server then state")
    func serverThenState() {
        var handshake = VoiceGatewayHandshake()
        handshake.begin(guildID: "guild", channelID: "channel", userID: "bot")

        guard case .waiting = handshake.receive(
            .init(guildID: "guild", endpoint: "voice.example.test", token: "token")
        ) else {
            Issue.record("Expected the server event to wait for voice state")
            return
        }

        guard case .ready(let credentials) = handshake.receive(
            .init(guildID: "guild", channelID: "channel", userID: "bot", sessionID: "session")
        ) else {
            Issue.record("Expected reverse event order to complete")
            return
        }
        #expect(credentials.sessionID == "session")
    }

    @Test("ignores unrelated voice state")
    func ignoresUnrelatedEvents() {
        var handshake = VoiceGatewayHandshake()
        handshake.begin(guildID: "guild", channelID: "channel", userID: "bot")

        let events: [VoiceGatewayHandshake.VoiceStateEvent] = [
            .init(guildID: "other-guild", channelID: "channel", userID: "bot", sessionID: "session"),
            .init(guildID: "guild", channelID: "other-channel", userID: "bot", sessionID: "session"),
            .init(guildID: "guild", channelID: "channel", userID: "other-user", sessionID: "session"),
            .init(guildID: nil, channelID: "channel", userID: "bot", sessionID: "session"),
        ]

        for event in events {
            guard case .ignored = handshake.receive(event) else {
                Issue.record("An unrelated event mutated the pending handshake")
                return
            }
        }
        #expect(handshake.generation(for: "guild") != nil)
    }

    @Test("rejects empty capability fields without completing")
    func rejectsEmptyFields() {
        var handshake = VoiceGatewayHandshake()
        let generation = handshake.begin(guildID: "guild", channelID: "channel", userID: "bot")

        assertRejection(
            handshake.receive(.init(guildID: "guild", channelID: "channel", userID: "bot", sessionID: "  ")),
            generation: generation,
            rejection: .emptySessionID
        )
        assertRejection(
            handshake.receive(.init(guildID: "guild", endpoint: nil, token: "token")),
            generation: generation,
            rejection: .emptyEndpoint
        )
        assertRejection(
            handshake.receive(.init(guildID: "guild", endpoint: "  ", token: "token")),
            generation: generation,
            rejection: .emptyEndpoint
        )
        assertRejection(
            handshake.receive(.init(guildID: "guild", endpoint: "voice.example.test", token: "  ")),
            generation: generation,
            rejection: .emptyToken
        )
        #expect(handshake.generation(for: "guild") == generation)
    }

    @Test("matching self leave cancels only the active guild generation")
    func selfLeaveCancels() {
        var handshake = VoiceGatewayHandshake()
        let oldGeneration = handshake.begin(guildID: "guild", channelID: "first", userID: "bot")
        let activeGeneration = handshake.begin(guildID: "guild", channelID: "second", userID: "bot")

        guard case .ignored = handshake.cancel(guildID: "guild", generation: oldGeneration) else {
            Issue.record("A stale generation must not cancel its replacement")
            return
        }
        guard case .cancelled(let cancelledGeneration) = handshake.receive(
            .init(guildID: "guild", channelID: nil, userID: "bot", sessionID: "session")
        ) else {
            Issue.record("Expected a matching self leave to cancel")
            return
        }
        #expect(cancelledGeneration == activeGeneration)
        #expect(handshake.generation(for: "guild") == nil)
    }

    @Test("credential descriptions redact the token")
    func redactsToken() {
        var handshake = VoiceGatewayHandshake()
        handshake.begin(guildID: "guild", channelID: "channel", userID: "bot")
        _ = handshake.receive(
            .init(guildID: "guild", channelID: "channel", userID: "bot", sessionID: "session")
        )
        guard case .ready(let credentials) = handshake.receive(
            .init(guildID: "guild", endpoint: "voice.example.test", token: "never-print-this")
        ) else {
            Issue.record("Expected credentials")
            return
        }

        #expect(!String(describing: credentials).contains("never-print-this"))
        #expect(!String(reflecting: credentials).contains("never-print-this"))
        #expect(String(describing: credentials).contains("<redacted>"))
    }

    private func assertRejection(
        _ outcome: VoiceGatewayHandshake.Outcome,
        generation: VoiceGatewayHandshake.Generation,
        rejection: VoiceGatewayHandshake.Rejection,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .rejected(let receivedGeneration, let receivedRejection) = outcome else {
            Issue.record("Expected rejection", sourceLocation: sourceLocation)
            return
        }
        #expect(receivedGeneration == generation, sourceLocation: sourceLocation)
        #expect(receivedRejection == rejection, sourceLocation: sourceLocation)
    }
}
