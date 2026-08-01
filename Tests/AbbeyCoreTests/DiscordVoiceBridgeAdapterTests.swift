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
        let credentials = makeCredentials()
        let source = CredentialSource(credentials: credentials)
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { _, _ in .requested(credentials.generation) },
            consume: { await source.take($0) },
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

        await #expect(throws: CancellationError.self) {
            _ = try await adapter.awaitGatewayPair()
        }
        #expect(await source.consumeCount == 1)
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
        let credentials = makeCredentials()
        let adapter = DiscordVoiceBridgeAdapter(
            request: { _, _ in .requested(credentials.generation) },
            consume: { _ in nil },
            leave: { await recorder.record($0) }
        )
        await adapter.leaveVoice(guildID: "guild")
        #expect(await recorder.guildIDs == ["guild"])
    }

    @Test("rejected replacement preserves the accepted attempt")
    func rejectedReplacementPreservesAcceptedAttempt() async throws {
        let credentials = makeCredentials()
        let requests = RequestOutcomeSource(
            outcomes: [.requested(credentials.generation), .requestInProgress]
        )
        let source = CredentialSource(credentials: credentials)
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { guildID, channelID in await requests.take(guildID, channelID) },
            consume: { await source.take($0) },
            leave: { _ in }
        )

        try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
        await #expect(throws: DiscordVoiceBridgeAdapterError.requestInProgress) {
            try await adapter.requestGatewayState(guildID: "other", channelID: "other")
        }

        let pair = try await adapter.awaitGatewayPair()
        #expect(pair.serverID == "guild")
        #expect(pair.channelID == "channel")
        #expect(await source.consumeCount == 1)
    }

    @Test("leave invalidates a suspended credential wait")
    func leaveInvalidatesSuspendedWait() async throws {
        let credentials = makeCredentials()
        let source = CredentialRaceSource()
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { _, _ in .requested(credentials.generation) },
            consume: { await source.take($0) },
            leave: { _ in }
        )

        try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
        let waiter = Task { try await adapter.awaitGatewayPair() }
        while await source.firstConsumeSuspended == false { await Task.yield() }

        await adapter.leaveVoice(guildID: " guild ")
        await source.resolveFirst(credentials)

        await #expect(throws: CancellationError.self) {
            _ = try await waiter.value
        }
    }

    @Test("leave tombstones a request suspended before producer acceptance")
    func leaveDuringSuspendedRequestCannotResurrectAttempt() async throws {
        let credentials = makeCredentials()
        let requests = SuspendedAdapterRequestSource()
        let leaves = LeaveRecorder()
        let adapter = DiscordVoiceBridgeAdapter(
            request: { guildID, channelID in
                await requests.take(guildID: guildID, channelID: channelID)
            },
            consume: { _ in credentials },
            leave: { await leaves.record($0) }
        )

        let request = Task {
            try await adapter.requestGatewayState(guildID: " guild ", channelID: " channel ")
        }
        while await requests.isSuspended == false { await Task.yield() }

        await adapter.leaveVoice(guildID: "guild")
        await requests.resolve(.requested(credentials.generation))

        await #expect(throws: CancellationError.self) {
            try await request.value
        }
        await #expect(throws: CancellationError.self) {
            _ = try await adapter.awaitGatewayPair()
        }
        #expect(await leaves.guildIDs == ["guild", "guild"])
    }

    @Test("cancellation after consume discards the delivered credential")
    func cancellationAfterConsumeDiscardsCredential() async throws {
        let credentials = makeCredentials()
        let source = CredentialRaceSource()
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { _, _ in .requested(credentials.generation) },
            consume: { await source.take($0) },
            leave: { _ in }
        )

        try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
        let waiter = Task { try await adapter.awaitGatewayPair() }
        while await source.firstConsumeSuspended == false { await Task.yield() }

        waiter.cancel()
        await source.resolveFirst(credentials)

        await #expect(throws: CancellationError.self) {
            _ = try await waiter.value
        }
        await #expect(throws: CancellationError.self) {
            _ = try await adapter.awaitGatewayPair()
        }
    }

    @Test("secondary waiter cannot cancel the credential owner")
    func secondaryWaiterCannotCancelCredentialOwner() async throws {
        let credentials = makeCredentials()
        let source = CredentialRaceSource()
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { _, _ in .requested(credentials.generation) },
            consume: { await source.take($0) },
            leave: { _ in }
        )

        try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
        let primary = Task { try await adapter.awaitGatewayPair() }
        while await source.firstConsumeSuspended == false { await Task.yield() }

        let secondary = Task { try await adapter.awaitGatewayPair() }
        secondary.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await secondary.value
        }

        await source.resolveFirst(credentials)
        let pair = try await primary.value
        #expect(pair.serverID == "guild")
        #expect(pair.channelID == "channel")
    }

    @Test("request identifiers are canonicalized before gateway and broker use")
    func canonicalizesRequestIdentifiers() async throws {
        let credentials = makeCredentials()
        let requests = RequestOutcomeSource(outcomes: [.requested(credentials.generation)])
        let source = CredentialSource(credentials: credentials)
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { guildID, channelID in await requests.take(guildID, channelID) },
            consume: { await source.take($0) },
            leave: { _ in }
        )

        try await adapter.requestGatewayState(guildID: " guild\n", channelID: " channel ")
        let pair = try await adapter.awaitGatewayPair()

        #expect(pair.serverID == "guild")
        #expect(await requests.targets == [.init(guildID: "guild", channelID: "channel")])
    }

    @Test("same-target late A credentials cannot satisfy B")
    func sameTargetLateCredentialsCannotSatisfyReplacement() async throws {
        let credentials = makeCredentialSequence(markers: ["a", "b"])
        let credentialA = credentials[0]
        let credentialB = credentials[1]
        let source = CredentialRaceSource()
        let requests = RequestOutcomeSource(
            outcomes: [.requested(credentialA.generation), .requested(credentialB.generation)]
        )
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { guildID, channelID in await requests.take(guildID, channelID) },
            consume: { await source.take($0) },
            leave: { _ in }
        )

        try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
        let attemptA = Task { try await adapter.awaitGatewayPair() }
        while await source.firstConsumeSuspended == false { await Task.yield() }

        try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
        let attemptB = Task { try await adapter.awaitGatewayPair() }
        await source.enqueue(credentialB)
        await source.resolveFirst(credentialA)

        let pairB = try await attemptB.value
        #expect(pairB.serverID == "guild")
        #expect(pairB.channelID == "channel")
        #expect(pairB.token == "token-b")
        await #expect(throws: CancellationError.self) {
            _ = try await attemptA.value
        }
    }

    @Test("credentials published during B request remain unavailable to A")
    func credentialsDuringRequestCommitRemainGenerationScoped() async throws {
        let credentials = makeCredentialSequence(markers: ["a", "b"])
        let credentialA = credentials[0]
        let credentialB = credentials[1]
        let source = CredentialSource(credentials: [])
        let requests = RequestCommitRaceSource(
            first: credentialA.generation,
            second: credentialB,
            credentials: source
        )
        let adapter = DiscordVoiceBridgeAdapter(
            sleeper: { _ in await Task.yield() },
            request: { guildID, channelID in await requests.take(guildID, channelID) },
            consume: { await source.take($0) },
            leave: { _ in }
        )

        try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
        let attemptA = Task { try await adapter.awaitGatewayPair() }
        while await source.consumeCount == 0 { await Task.yield() }

        let requestB = Task {
            try await adapter.requestGatewayState(guildID: "guild", channelID: "channel")
        }
        while await requests.secondCredentialPublished == false { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(await source.contains(credentialB.generation))

        await requests.finishSecondRequest()
        try await requestB.value
        let pair = try await adapter.awaitGatewayPair()

        #expect(pair.serverID == "guild")
        #expect(pair.channelID == "channel")
        #expect(pair.token == "token-b")
        await #expect(throws: CancellationError.self) {
            _ = try await attemptA.value
        }
    }

    private func makeAdapter(requestOutcome: VoiceUpdateResult) -> DiscordVoiceBridgeAdapter {
        let credentials = makeCredentials()
        return DiscordVoiceBridgeAdapter(
            sleeper: { _ in try await Task.sleep(for: .seconds(60)) },
            request: { _, _ in
                switch requestOutcome {
                case .requested: .requested(credentials.generation)
                case .requestInProgress: .requestInProgress
                case .gatewayUnavailable: .gatewayUnavailable
                case .invalidIdentifiers: .invalidIdentifiers
                }
            },
            consume: { _ in nil },
            leave: { _ in }
        )
    }

    private func makeCredentialSequence(
        guildID: String = "guild",
        channelID: String = "channel",
        markers: [String]
    ) -> [VoiceGatewayHandshake.Credentials] {
        var handshake = VoiceGatewayHandshake()
        return markers.map { marker in
            guard let generation = handshake.begin(
                guildID: guildID,
                channelID: channelID,
                userID: "user-\(marker)"
            ) else {
                Issue.record("Expected a handshake generation")
                fatalError("test setup failed")
            }
            _ = handshake.receive(
                .init(
                    guildID: guildID,
                    channelID: channelID,
                    userID: "user-\(marker)",
                    sessionID: "session-\(marker)"
                )
            )
            let outcome = handshake.receive(
                .init(
                    guildID: guildID,
                    endpoint: "voice-\(marker).example.invalid",
                    token: "token-\(marker)"
                )
            )
            guard case .ready(let credentials) = outcome else {
                Issue.record("Expected a ready credential pair")
                fatalError("test setup failed")
            }
            let expired = handshake.expire(guildID: guildID, generation: generation)
            #expect(expired)
            return credentials
        }
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

private actor SuspendedAdapterRequestSource {
    private var continuation: CheckedContinuation<DiscordVoiceGatewayPairRequestOutcome, Never>?
    private(set) var isSuspended = false

    func take(
        guildID _: String,
        channelID _: String
    ) async -> DiscordVoiceGatewayPairRequestOutcome {
        isSuspended = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ outcome: DiscordVoiceGatewayPairRequestOutcome) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
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

    func take(
        _ generation: VoiceGatewayHandshake.Generation
    ) -> VoiceGatewayHandshake.Credentials? {
        consumeCount += 1
        guard let index = credentials.firstIndex(where: { $0.generation == generation }) else {
            return nil
        }
        return credentials.remove(at: index)
    }

    func enqueue(_ credential: VoiceGatewayHandshake.Credentials) {
        credentials.append(credential)
    }

    func contains(_ generation: VoiceGatewayHandshake.Generation) -> Bool {
        credentials.contains(where: { $0.generation == generation })
    }
}

private actor CredentialRaceSource {
    private var firstContinuation: CheckedContinuation<VoiceGatewayHandshake.Credentials?, Never>?
    private(set) var firstConsumeSuspended = false
    private var consumeCount = 0
    private var queued: [VoiceGatewayHandshake.Credentials] = []

    func take(
        _ generation: VoiceGatewayHandshake.Generation
    ) async -> VoiceGatewayHandshake.Credentials? {
        consumeCount += 1
        if consumeCount == 1 {
            firstConsumeSuspended = true
            return await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        guard let index = queued.firstIndex(where: { $0.generation == generation }) else {
            return nil
        }
        return queued.remove(at: index)
    }

    func resolveFirst(_ credentials: VoiceGatewayHandshake.Credentials) {
        let continuation = firstContinuation
        firstContinuation = nil
        continuation?.resume(returning: credentials)
    }

    func enqueue(_ credentials: VoiceGatewayHandshake.Credentials) {
        queued.append(credentials)
    }
}

private struct RequestedVoiceTarget: Equatable, Sendable {
    let guildID: String
    let channelID: String
}

private actor RequestOutcomeSource {
    private var outcomes: [DiscordVoiceGatewayPairRequestOutcome]
    private(set) var targets: [RequestedVoiceTarget] = []

    init(outcomes: [DiscordVoiceGatewayPairRequestOutcome]) {
        self.outcomes = outcomes
    }

    func take(
        _ guildID: String,
        _ channelID: String
    ) -> DiscordVoiceGatewayPairRequestOutcome {
        targets.append(.init(guildID: guildID, channelID: channelID))
        guard !outcomes.isEmpty else { return .requestInProgress }
        return outcomes.removeFirst()
    }
}

private actor RequestCommitRaceSource {
    private let first: VoiceGatewayHandshake.Generation
    private let second: VoiceGatewayHandshake.Credentials
    private let credentials: CredentialSource
    private var requestCount = 0
    private var secondContinuation: CheckedContinuation<Void, Never>?
    private(set) var secondCredentialPublished = false

    init(
        first: VoiceGatewayHandshake.Generation,
        second: VoiceGatewayHandshake.Credentials,
        credentials: CredentialSource
    ) {
        self.first = first
        self.second = second
        self.credentials = credentials
    }

    func take(
        _ guildID: String,
        _ channelID: String
    ) async -> DiscordVoiceGatewayPairRequestOutcome {
        requestCount += 1
        guard requestCount == 2 else { return .requested(first) }
        await credentials.enqueue(second)
        secondCredentialPublished = true
        await withCheckedContinuation { continuation in
            secondContinuation = continuation
        }
        return .requested(second.generation)
    }

    func finishSecondRequest() {
        let continuation = secondContinuation
        secondContinuation = nil
        continuation?.resume()
    }
}

private actor LeaveRecorder {
    private(set) var guildIDs: [String] = []

    func record(_ guildID: String) {
        guildIDs.append(guildID)
    }
}
