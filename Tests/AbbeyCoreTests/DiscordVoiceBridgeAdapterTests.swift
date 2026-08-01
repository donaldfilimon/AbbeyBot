import Testing
@testable import AbbeyCore

@Suite("Discord voice bridge adapter")
struct DiscordVoiceBridgeAdapterTests {
    @Test("request outcomes map to redacted adapter errors")
    func requestOutcomeMapping() async throws {
        for (outcome, expected) in [
            (VoiceUpdateResult.gatewayUnavailable, DiscordVoiceBridgeAdapterError.gatewayUnavailable),
            (.requestInProgress, .requestInProgress),
            (.invalidIdentifiers, .invalidIdentifiers),
        ] {
            let adapter = makeAdapter(requestOutcome: outcome)
            await #expect(throws: expected) {
                try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
            }
        }

        try await makeAdapter(requestOutcome: .requested)
            .requestGatewayState(guildID: "guild", channelID: "channel")
    }

    @Test("credentials are consumed once and converted without diagnostic exposure")
    func consumesCredentialsOnce() async throws {
        let source = CredentialSource(credentials: makeCredentials())
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { _, _ in .requested },
            consume: { await source.take() },
            leave: { _ in }
        )

        let pair = try await adapter.awaitGatewayPair()
        #expect(pair.endpoint == "voice.example.invalid")
        #expect(pair.token == "ephemeral-token")
        #expect(pair.sessionID == "session")
        #expect(pair.serverID == "guild")
        #expect(pair.userID == "user")
        #expect(await source.consumeCount == 1)

        let diagnostics = "\(pair) \(String(reflecting: pair)) \(String(describing: pair.customMirror))"
        #expect(!diagnostics.contains("ephemeral-token"))
        #expect(!diagnostics.contains("voice.example.invalid"))
        #expect(!diagnostics.contains("session"))
    }

    @Test("credential wait obeys cancellation")
    func cancellation() async throws {
        let adapter = makeAdapter(requestOutcome: .requested)
        let task = Task { try await adapter.awaitGatewayPair() }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("leave is forwarded once")
    func leaveForwarding() async {
        let recorder = LeaveRecorder()
        let adapter = DiscordVoiceBridgeAdapter(
            request: { _, _ in .requested },
            consume: { nil },
            leave: { await recorder.record($0) }
        )
        await adapter.leaveVoice(guildID: "guild")
        #expect(await recorder.guildIDs == ["guild"])
    }

    private func makeAdapter(requestOutcome: VoiceUpdateResult) -> DiscordVoiceBridgeAdapter {
        DiscordVoiceBridgeAdapter(
            sleeper: { _ in try await Task.sleep(for: .seconds(60)) },
            request: { _, _ in requestOutcome },
            consume: { nil },
            leave: { _ in }
        )
    }

    private func makeCredentials() -> VoiceGatewayHandshake.Credentials {
        var handshake = VoiceGatewayHandshake()
        _ = handshake.begin(guildID: "guild", channelID: "channel", userID: "user")
        _ = handshake.receive(
            .init(guildID: "guild", channelID: "channel", userID: "user", sessionID: "session")
        )
        let outcome = handshake.receive(
            .init(guildID: "guild", endpoint: "voice.example.invalid", token: "ephemeral-token")
        )
        guard case .ready(let credentials) = outcome else {
            Issue.record("Expected a ready credential pair")
            fatalError("test setup failed")
        }
        return credentials
    }
}

private actor CredentialSource {
    private var credentials: VoiceGatewayHandshake.Credentials?
    private(set) var consumeCount = 0

    init(credentials: VoiceGatewayHandshake.Credentials) {
        self.credentials = credentials
    }

    func take() -> VoiceGatewayHandshake.Credentials? {
        consumeCount += 1
        defer { credentials = nil }
        return credentials
    }
}

private actor LeaveRecorder {
    private(set) var guildIDs: [String] = []

    func record(_ guildID: String) {
        guildIDs.append(guildID)
    }
}
