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

        try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
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
        try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
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

    @Test("superseded waiter cannot steal replacement credentials")
    func supersededWaiterCannotStealReplacementCredentials() async throws {
        let source = CredentialRaceSource()
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { _, _ in .requested },
            consume: { await source.take() },
            leave: { _ in }
        )

        try await adapter.requestGatewayState(guildID: "guild-a", channelID: "channel-a")
        let attemptA = Task { try await adapter.awaitGatewayPair() }
        while await source.firstConsumeSuspended == false { await Task.yield() }

        try await adapter.requestGatewayState(guildID: "guild-b", channelID: "channel-b")
        let attemptB = Task { try await adapter.awaitGatewayPair() }
        await source.resolveFirst(
            makeCredentials(
                guildID: "guild-b",
                channelID: "channel-b",
                marker: "b"
            )
        )

        let pairB = try await attemptB.value
        #expect(pairB.serverID == "guild-b")
        #expect(pairB.channelID == "channel-b")
        #expect(pairB.token == "token-b")
        await #expect(throws: CancellationError.self) {
            _ = try await attemptA.value
        }
    }

    @Test("late credentials from superseded target are ignored")
    func lateSupersededCredentialsAreIgnored() async throws {
        let source = CredentialSource(
            credentials: [
                makeCredentials(guildID: "guild-a", channelID: "channel-a", marker: "a"),
                makeCredentials(guildID: "guild-b", channelID: "channel-b", marker: "b"),
            ]
        )
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { _, _ in .requested },
            consume: { await source.take() },
            leave: { _ in }
        )

        try await adapter.requestGatewayState(guildID: "guild-a", channelID: "channel-a")
        try await adapter.requestGatewayState(guildID: "guild-b", channelID: "channel-b")
        let pair = try await adapter.awaitGatewayPair()

        #expect(pair.serverID == "guild-b")
        #expect(pair.channelID == "channel-b")
        #expect(pair.token == "token-b")
        #expect(await source.consumeCount == 2)
    }

    private func makeAdapter(requestOutcome: VoiceUpdateResult) -> DiscordVoiceBridgeAdapter {
        DiscordVoiceBridgeAdapter(
            sleeper: { _ in try await Task.sleep(for: .seconds(60)) },
            request: { _, _ in requestOutcome },
            consume: { nil },
            leave: { _ in }
        )
    }

    private func makeCredentials(
        guildID: String = "guild",
        channelID: String = "channel",
        marker: String = ""
    ) -> VoiceGatewayHandshake.Credentials {
        let suffix = marker.isEmpty ? "" : "-\(marker)"
        var handshake = VoiceGatewayHandshake()
        _ = handshake.begin(guildID: guildID, channelID: channelID, userID: "user\(suffix)")
        _ = handshake.receive(
            .init(
                guildID: guildID,
                channelID: channelID,
                userID: "user\(suffix)",
                sessionID: "session\(suffix)"
            )
        )
        let outcome = handshake.receive(
            .init(
                guildID: guildID,
                endpoint: "voice\(suffix).example.invalid",
                token: marker.isEmpty ? "ephemeral-token" : "token\(suffix)"
            )
        )
        guard case .ready(let credentials) = outcome else {
            Issue.record("Expected a ready credential pair")
            fatalError("test setup failed")
        }
        return credentials
    }
}

private actor CredentialSource {
    private var credentials: [VoiceGatewayHandshake.Credentials]
    private(set) var consumeCount = 0

    init(credentials: VoiceGatewayHandshake.Credentials) {
        self.credentials = [credentials]
    }

    init(credentials: [VoiceGatewayHandshake.Credentials]) {
        self.credentials = credentials
    }

    func take() -> VoiceGatewayHandshake.Credentials? {
        consumeCount += 1
        guard !credentials.isEmpty else { return nil }
        return credentials.removeFirst()
    }
}

private actor CredentialRaceSource {
    private var firstContinuation: CheckedContinuation<VoiceGatewayHandshake.Credentials?, Never>?
    private(set) var firstConsumeSuspended = false
    private var consumeCount = 0

    func take() async -> VoiceGatewayHandshake.Credentials? {
        consumeCount += 1
        guard consumeCount == 1 else { return nil }
        firstConsumeSuspended = true
        return await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func resolveFirst(_ credentials: VoiceGatewayHandshake.Credentials) {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume(returning: credentials)
    }
}

private actor LeaveRecorder {
    private(set) var guildIDs: [String] = []

    func record(_ guildID: String) {
        guildIDs.append(guildID)
    }
}
