import Testing
@testable import AbbeyCore

@Suite("Discord voice Gateway handshake")
struct VoiceGatewayHandshakeTests {
    @Test("pairs state then server and emits credentials once")
    func stateThenServer() {
        var handshake = VoiceGatewayHandshake()
        guard let generation = handshake.begin(guildID: "guild", channelID: "channel", userID: "bot") else {
            Issue.record("Expected handshake generation")
            return
        }

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
        #expect(handshake.begin(guildID: "guild", channelID: "channel", userID: "bot") != nil)

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
        #expect(handshake.begin(guildID: "guild", channelID: "channel", userID: "bot") != nil)

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
        guard let generation = handshake.begin(guildID: "guild", channelID: "channel", userID: "bot") else {
            Issue.record("Expected handshake generation")
            return
        }

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

    @Test("overlapping join is rejected until leave acknowledgement")
    func overlappingJoinIsSerialized() {
        var handshake = VoiceGatewayHandshake()
        guard let activeGeneration = handshake.begin(guildID: "guild", channelID: "first", userID: "bot") else {
            Issue.record("Expected initial generation")
            return
        }
        #expect(handshake.begin(guildID: "guild", channelID: "second", userID: "bot") == nil)

        guard case .cancelled(let cancelledGeneration) = handshake.cancel(
            guildID: "guild",
            generation: activeGeneration
        ) else {
            Issue.record("Expected active generation cancellation")
            return
        }
        #expect(cancelledGeneration == activeGeneration)
        #expect(handshake.begin(guildID: "guild", channelID: "second", userID: "bot") == nil)

        guard case .cancelled(let acknowledgedGeneration) = handshake.receive(
            .init(guildID: "guild", channelID: nil, userID: "bot", sessionID: "session")
        ) else {
            Issue.record("Expected leave acknowledgement")
            return
        }
        #expect(acknowledgedGeneration == activeGeneration)
        guard let replacementGeneration = handshake.begin(
            guildID: "guild",
            channelID: "second",
            userID: "bot"
        ) else {
            Issue.record("Expected replacement after leave acknowledgement")
            return
        }
        #expect(replacementGeneration != activeGeneration)
    }

    @Test("credential diagnostics redact every capability field")
    func redactsCredentials() {
        var handshake = VoiceGatewayHandshake()
        #expect(handshake.begin(guildID: "guild", channelID: "channel", userID: "bot") != nil)
        _ = handshake.receive(
            .init(guildID: "guild", channelID: "channel", userID: "bot", sessionID: "session")
        )
        guard case .ready(let credentials) = handshake.receive(
            .init(guildID: "guild", endpoint: "voice.example.test", token: "never-print-this")
        ) else {
            Issue.record("Expected credentials")
            return
        }

        let secrets = ["session", "voice.example.test", "never-print-this"]
        var dumped = ""
        dump(credentials, to: &dumped)
        let reflectedChildren = Mirror(reflecting: credentials).children
            .map { String(reflecting: $0.value) }
            .joined(separator: " ")
        for secret in secrets {
            #expect(!String(describing: credentials).contains(secret))
            #expect(!String(reflecting: credentials).contains(secret))
            #expect(!dumped.contains(secret))
            #expect(!reflectedChildren.contains(secret))
        }
        #expect(String(describing: credentials).contains("<redacted>"))
    }

    @Test("null endpoint invalidates server capability before and after readiness")
    func nullEndpointInvalidatesCapability() {
        var handshake = VoiceGatewayHandshake()
        #expect(handshake.begin(guildID: "guild", channelID: "channel", userID: "bot") != nil)

        guard case .waiting = handshake.receive(
            .init(guildID: "guild", endpoint: "old.example.test", token: "old-token")
        ) else {
            Issue.record("Expected server half to wait for state")
            return
        }
        assertRejection(
            handshake.receive(.init(guildID: "guild", endpoint: nil, token: "replacement-token")),
            generation: handshake.generation(for: "guild")!,
            rejection: .emptyEndpoint
        )
        guard case .waiting = handshake.receive(
            .init(guildID: "guild", channelID: "channel", userID: "bot", sessionID: "session")
        ) else {
            Issue.record("A null endpoint must prevent use of the old server half")
            return
        }

        guard case .ready = handshake.receive(
            .init(guildID: "guild", endpoint: "new.example.test", token: "new-token")
        ) else {
            Issue.record("Expected fresh allocation to restore readiness")
            return
        }
        assertRejection(
            handshake.receive(.init(guildID: "guild", endpoint: nil, token: "newer-token")),
            generation: handshake.generation(for: "guild")!,
            rejection: .emptyEndpoint
        )
        guard case .waiting = handshake.receive(
            .init(guildID: "guild", channelID: "channel", userID: "bot", sessionID: "session")
        ) else {
            Issue.record("Post-ready null endpoint must invalidate current capability")
            return
        }
    }

    @Test("reset drops pending and leave barriers without reusing generations")
    func resetDropsCapabilityState() {
        var handshake = VoiceGatewayHandshake()
        guard let first = handshake.begin(guildID: "guild", channelID: "channel", userID: "bot") else {
            Issue.record("Expected initial generation")
            return
        }
        _ = handshake.receive(
            .init(guildID: "guild", endpoint: "voice.example.test", token: "token")
        )
        handshake.reset()
        #expect(handshake.generation(for: "guild") == nil)

        guard let second = handshake.begin(guildID: "guild", channelID: "channel", userID: "bot") else {
            Issue.record("Expected generation after reset")
            return
        }
        #expect(second != first)
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
