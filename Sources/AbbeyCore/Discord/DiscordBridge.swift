import Foundation
import DiscordBM
import Logging

enum DiscordVoiceGatewayPairRequestOutcome: Equatable, Sendable {
    case requested(VoiceGatewayHandshake.Generation)
    case cancelled
    case requestInProgress
    case gatewayUnavailable
    case invalidIdentifiers

    var voiceUpdateResult: VoiceUpdateResult {
        switch self {
        case .requested: .requested
        case .cancelled: .requestInProgress
        case .requestInProgress: .requestInProgress
        case .gatewayUnavailable: .gatewayUnavailable
        case .invalidIdentifiers: .invalidIdentifiers
        }
    }
}

enum DiscordVoiceLeaveCompletion: Equatable, Sendable {
    case acknowledged
    case expired
    case gatewayClosed
}

actor DiscordVoiceLeaveSignal {
    private var completion: DiscordVoiceLeaveCompletion?
    private var waiters: [CheckedContinuation<DiscordVoiceLeaveCompletion, Never>] = []

    func wait() async -> DiscordVoiceLeaveCompletion {
        if let completion { return completion }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve(_ completion: DiscordVoiceLeaveCompletion) {
        guard self.completion == nil else { return }
        self.completion = completion
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume(returning: completion)
        }
    }
}

struct DiscordVoiceLeaveLease: Sendable {
    let signal: DiscordVoiceLeaveSignal
    let ownsCleanupOpcode: Bool
}

struct DiscordVoiceLeaveCoordinator: Sendable {
    private struct Operation: Sendable {
        let guildID: String
        let generation: VoiceGatewayHandshake.Generation
        let signal: DiscordVoiceLeaveSignal
    }

    private var operation: Operation?

    var activeGuildID: String? { operation?.guildID }

    mutating func acquire(
        guildID: String,
        generation: VoiceGatewayHandshake.Generation
    ) -> DiscordVoiceLeaveLease {
        if let operation,
           operation.guildID == guildID,
           operation.generation == generation
        {
            return .init(signal: operation.signal, ownsCleanupOpcode: false)
        }
        let signal = DiscordVoiceLeaveSignal()
        operation = .init(guildID: guildID, generation: generation, signal: signal)
        return .init(signal: signal, ownsCleanupOpcode: true)
    }

    mutating func complete(
        guildID: String,
        generation: VoiceGatewayHandshake.Generation
    ) -> DiscordVoiceLeaveSignal? {
        guard let operation,
              operation.guildID == guildID,
              operation.generation == generation
        else { return nil }
        self.operation = nil
        return operation.signal
    }

    mutating func completeCurrent() -> DiscordVoiceLeaveSignal? {
        defer { operation = nil }
        return operation?.signal
    }
}

private struct DiscordUntrackedVoiceLeaveOperation: Sendable {
    let id: UInt64
    let guildID: String
    let signal: DiscordVoiceLeaveSignal
}

public enum DiscordConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case failed

    /// Title-case label for dashboards and forms (not the wire `rawValue`).
    public var displayName: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        }
    }
}

/// Pure generation-scoped lifecycle used by `DiscordBridge` and deterministic
/// tests. DiscordBM's `connect()` returns after spawning its WebSocket task, so
/// only a current-generation READY is authoritative.
struct DiscordGatewayLifecycle: Sendable {
    struct Generation: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    static let streamEndedError = "Discord Gateway event stream ended unexpectedly."
    static let streamFailedError = "Discord Gateway event stream failed."

    private(set) var state: DiscordConnectionState = .disconnected
    private(set) var lastError: String?
    private(set) var generation = Generation(value: 0)

    @discardableResult
    mutating func beginConnecting() -> Generation {
        advanceGeneration()
        state = .connecting
        lastError = nil
        return generation
    }

    @discardableResult
    mutating func receiveReady(generation candidate: Generation) -> Bool {
        guard candidate == generation, state == .connecting else { return false }
        state = .connected
        lastError = nil
        return true
    }

    @discardableResult
    mutating func eventStreamEnded(generation candidate: Generation) -> Bool {
        fail(generation: candidate, message: Self.streamEndedError)
    }

    @discardableResult
    mutating func eventStreamFailed(generation candidate: Generation) -> Bool {
        fail(generation: candidate, message: Self.streamFailedError)
    }

    mutating func disconnect() {
        // Invalidate callbacks before any asynchronous teardown begins.
        advanceGeneration()
        state = .disconnected
        lastError = nil
    }

    mutating func failCurrentConfiguration() {
        state = .failed
        lastError = "DISCORD_BOT_TOKEN is empty"
    }

    func isCurrent(_ candidate: Generation) -> Bool {
        candidate == generation
    }

    private mutating func fail(generation candidate: Generation, message: String) -> Bool {
        guard candidate == generation, state != .disconnected else { return false }
        state = .failed
        lastError = message
        return true
    }

    private mutating func advanceGeneration() {
        generation = Generation(value: generation.value &+ 1)
    }
}

/// Owns the DiscordBM gateway manager and exposes connect/disconnect for desktop + server.
public actor DiscordBridge {
    public var state: DiscordConnectionState { lifecycle.state }
    public var lastError: String? { lifecycle.lastError }
    public private(set) var botUserId: String?
    /// Current voice-channel presence (gateway update only; no Opus/UDP audio).
    public private(set) var voiceChannelId: String?
    public private(set) var voiceGuildId: String?

    private var gateway: BotGatewayManager?
    private var voiceGatewayCredentials: VoiceGatewayHandshake.Credentials?
    private var voiceGatewayHandshake = VoiceGatewayHandshake()
    private var voiceHandshakeDeadlineTask: Task<Void, Never>?
    private var voiceLeaveSendTask: Task<Void, Never>?
    private var voiceLeaveCoordinator = DiscordVoiceLeaveCoordinator()
    private var nextUntrackedVoiceLeaveID: UInt64 = 0
    private var untrackedVoiceLeaveOperation: DiscordUntrackedVoiceLeaveOperation?
    private var eventTask: Task<Void, Never>?
    private var lifecycle = DiscordGatewayLifecycle()
    private let voiceHandshakeTimeout: Duration
    private let voiceHandshakeSleep: @Sendable (Duration) async throws -> Void
    private let logger = Logger(label: "AbbeyBot.DiscordBridge")

    public init() {
        self.voiceHandshakeTimeout = .seconds(30)
        self.voiceHandshakeSleep = { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(
        voiceHandshakeTimeout: Duration,
        voiceHandshakeSleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.voiceHandshakeTimeout = max(.milliseconds(1), voiceHandshakeTimeout)
        self.voiceHandshakeSleep = voiceHandshakeSleep
    }

    public var client: (any DiscordClient)? {
        gateway?.client
    }

    /// True when a live BotGatewayManager is held (false under dry-run).
    public var hasGateway: Bool {
        gateway != nil
    }

    public func connect(
        token: String,
        hooks: DiscordEventHooks,
        presenceActivityName: String = "AbbeyBot",
        dryRun: Bool = AppConfig.shared.dryRun
    ) async {
        await disconnect()
        if dryRun {
            let generation = lifecycle.beginConnecting()
            _ = lifecycle.receiveReady(generation: generation)
            botUserId = "dry-run"
            logger.info("dry-run: would connect (presenceActivity=\(presenceActivityName)); gateway skipped")
            await hooks.onReady("dry-run")
            return
        }
        guard !token.isEmpty else {
            lifecycle.failCurrentConfiguration()
            return
        }
        let generation = lifecycle.beginConnecting()

        let bot = await BotGatewayManager(
            token: token,
            presence: .init(
                activities: [.init(name: presenceActivityName, type: .listening)],
                status: .online,
                afk: false
            ),
            intents: [
                .guildMessages,
                .messageContent,
                .guildMembers,
                .directMessages,
                .guildMessageReactions,
                .guildVoiceStates
            ]
        )
        self.gateway = bot

        eventTask = Task { [weak self] in
            for await event in await bot.events {
                guard !Task.isCancelled, let self else { return }
                await self.handleGatewayEvent(event, hooks: hooks, generation: generation)
            }
            guard !Task.isCancelled else { return }
            await self?.noteEventStreamEnded(generation: generation)
        }

        await bot.connect()
    }

    public func disconnect() async {
        // Keep consuming Gateway events while the bounded voice-leave barrier
        // waits for Discord's self Voice State Update acknowledgement.
        if let guildId = voiceGuildId ?? voiceGatewayHandshake.activeGuildID {
            _ = await leaveVoiceAndWaitForAcknowledgement(guildId: guildId)
        }
        let untrackedLeaveSignal = untrackedVoiceLeaveOperation?.signal
        untrackedVoiceLeaveOperation = nil
        lifecycle.disconnect()
        eventTask?.cancel()
        eventTask = nil
        voiceHandshakeDeadlineTask?.cancel()
        voiceHandshakeDeadlineTask = nil
        voiceLeaveSendTask?.cancel()
        voiceLeaveSendTask = nil
        await gateway?.disconnect()
        gateway = nil
        botUserId = nil
        voiceChannelId = nil
        voiceGuildId = nil
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.reset()
        await resolveVoiceLeaveOperation(.gatewayClosed)
        if let untrackedLeaveSignal {
            await untrackedLeaveSignal.resolve(.gatewayClosed)
        }
    }

    /// Appear in a voice channel via gateway `Voice State Update` (self-mute + self-deaf).
    /// DiscordBM has no Opus/UDP — this is presence only, not audio.
    @discardableResult
    public func joinVoice(guildId: String, channelId: String) async -> VoiceUpdateResult {
        await requestVoiceGatewayPair(guildId: guildId, channelId: channelId).voiceUpdateResult
    }

    /// Begins the producer-owned credential attempt before opcode 4 is sent and
    /// returns its opaque identity only to the internal media adapter.
    func requestVoiceGatewayPair(
        guildId: String,
        channelId: String
    ) async -> DiscordVoiceGatewayPairRequestOutcome {
        guard let gateway else { return .gatewayUnavailable }
        guard untrackedVoiceLeaveOperation == nil else { return .requestInProgress }
        let trimmedGuild = guildId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChannel = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuild.isEmpty, !trimmedChannel.isEmpty else { return .invalidIdentifiers }
        let handshakeResult = beginVoiceGatewayHandshake(guildId: trimmedGuild, channelId: trimmedChannel)
        guard case .requested = handshakeResult else { return handshakeResult }
        await gateway.updateVoiceState(
            payload: VoiceStateUpdate(
                guildId: GuildSnowflake(trimmedGuild),
                channelId: ChannelSnowflake(trimmedChannel),
                selfMute: true,
                selfDeaf: true
            )
        )
        guard case .requested(let generation) = handshakeResult,
              voiceGatewayHandshake.generation(for: trimmedGuild) == generation
        else {
            return .cancelled
        }
        return .requested(generation)
    }

    /// Leave voice by sending `channel_id: null` for the guild (defaults to tracked guild).
    @discardableResult
    public func leaveVoice(guildId: String? = nil) async -> VoiceUpdateResult {
        let result = await initiateVoiceLeave(
            guildId: guildId,
            forceUntrackedPresence: true
        )
        return result.outcome
    }

    /// Internal media path: do not permit a replacement opcode 4 until Discord
    /// acknowledges the old allocation or its generation-scoped deadline fires.
    func leaveVoiceAndWaitForAcknowledgement(guildId: String? = nil) async -> VoiceUpdateResult {
        let result = await initiateVoiceLeave(
            guildId: guildId,
            forceUntrackedPresence: false
        )
        if let signal = result.signal {
            _ = await signal.wait()
        }
        return result.outcome
    }

    private func initiateVoiceLeave(
        guildId: String?,
        forceUntrackedPresence: Bool
    ) async -> (outcome: VoiceUpdateResult, signal: DiscordVoiceLeaveSignal?) {
        guard let gateway else { return (.gatewayUnavailable, nil) }
        let trimmed = (guildId ?? voiceGuildId)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return (.invalidIdentifiers, nil) }
        let cancellation = voiceGatewayHandshake.cancel(guildID: trimmed)
        if voiceGatewayCredentials?.guildID == trimmed {
            voiceGatewayCredentials = nil
        }

        let generation: VoiceGatewayHandshake.Generation?
        switch cancellation {
        case .cancelled(let value):
            generation = value
        default:
            generation = voiceGatewayHandshake.leavingGeneration(for: trimmed)
        }

        guard let generation else {
            guard forceUntrackedPresence else {
                // Internal teardown is idempotent: if no producer generation
                // remains, cleanup is already complete.
                return (.requested, nil)
            }
            if let operation = untrackedVoiceLeaveOperation {
                guard operation.guildID == trimmed else {
                    return (.requestInProgress, nil)
                }
                _ = await operation.signal.wait()
                return (.requested, nil)
            }
            guard voiceGatewayHandshake.activeGuildID == nil,
                  voiceLeaveCoordinator.activeGuildID == nil
            else {
                return (.requestInProgress, nil)
            }
            // Preserve the public force-leave contract while bounding a stuck
            // send. Until the send completes or its Gateway epoch is closed,
            // a replacement request is rejected above.
            let signal = startUntrackedVoiceLeave(
                gateway: gateway,
                guildID: trimmed
            )
            _ = await signal.wait()
            return (.requested, nil)
        }

        let lease = voiceLeaveCoordinator.acquire(
            guildID: trimmed,
            generation: generation
        )
        if lease.ownsCleanupOpcode {
            scheduleVoiceLeaveDeadline(guildId: trimmed, generation: generation)
            voiceLeaveSendTask?.cancel()
            voiceLeaveSendTask = Task {
                guard !Task.isCancelled else { return }
                await gateway.updateVoiceState(
                    payload: VoiceStateUpdate(
                        guildId: GuildSnowflake(trimmed),
                        channelId: nil,
                        selfMute: true,
                        selfDeaf: true
                    )
                )
            }
        }
        return (.requested, lease.signal)
    }

    /// READY events must enter through `handleGatewayEvent`, which carries the
    /// connection generation. An unscoped callback cannot safely mutate state.
    func noteReady(userId _: String) {
        logger.warning("Ignoring unscoped Discord READY event")
    }

    /// Like READY, a failure without its originating generation is unsafe: a
    /// stale callback must not fail a replacement connection.
    func noteFailure(_: String) {
        logger.warning("Ignoring unscoped Discord Gateway failure")
    }
}

/// Callbacks from gateway handlers into the app engine (Sendable closures).
extension DiscordBridge {
    private func handleGatewayEvent(
        _ event: Gateway.Event,
        hooks: DiscordEventHooks,
        generation: DiscordGatewayLifecycle.Generation
    ) async {
        guard lifecycle.isCurrent(generation), state == .connecting || state == .connected else { return }

        if case .ready(let payload)? = event.data {
            guard lifecycle.receiveReady(generation: generation) else { return }
            let userId = payload.user.id.rawValue
            botUserId = userId
            await hooks.onReady(userId)
            return
        }

        await AbbeyGatewayHandler(
            event: event,
            hooks: hooks,
            bridge: self,
            generation: generation
        ).handleAsync()
    }

    private func noteEventStreamEnded(generation: DiscordGatewayLifecycle.Generation) async {
        guard lifecycle.eventStreamEnded(generation: generation) else { return }
        voiceHandshakeDeadlineTask?.cancel()
        voiceHandshakeDeadlineTask = nil
        await resolveVoiceLeaveOperation(.gatewayClosed)
        await resolveUntrackedVoiceLeaveOperation(.gatewayClosed)
        botUserId = nil
        voiceChannelId = nil
        voiceGuildId = nil
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.reset()
        gateway = nil
        eventTask = nil
        logger.error("Discord bridge failure: \(DiscordGatewayLifecycle.streamEndedError)")
    }

    private func noteEventStreamFailed(generation: DiscordGatewayLifecycle.Generation) async {
        guard lifecycle.eventStreamFailed(generation: generation) else { return }
        voiceHandshakeDeadlineTask?.cancel()
        voiceHandshakeDeadlineTask = nil
        await resolveVoiceLeaveOperation(.gatewayClosed)
        await resolveUntrackedVoiceLeaveOperation(.gatewayClosed)
        botUserId = nil
        voiceChannelId = nil
        voiceGuildId = nil
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.reset()
        gateway = nil
        eventTask = nil
        logger.error("Discord bridge failure: \(DiscordGatewayLifecycle.streamFailedError)")
    }

    /// Begins correlation before Gateway opcode 4 is sent.
    private func beginVoiceGatewayHandshake(
        guildId: String,
        channelId: String
    ) -> DiscordVoiceGatewayPairRequestOutcome {
        guard let botUserId else { return .gatewayUnavailable }
        guard let generation = voiceGatewayHandshake.begin(
            guildID: guildId,
            channelID: channelId,
            userID: botUserId
        ) else {
            return .requestInProgress
        }
        voiceGatewayCredentials = nil
        scheduleVoiceJoinDeadline(guildId: guildId, generation: generation)
        return .requested(generation)
    }

    private func scheduleVoiceJoinDeadline(
        guildId: String,
        generation: VoiceGatewayHandshake.Generation
    ) {
        voiceHandshakeDeadlineTask?.cancel()
        let timeout = voiceHandshakeTimeout
        let sleep = voiceHandshakeSleep
        voiceHandshakeDeadlineTask = Task { [weak self] in
            do {
                try await sleep(timeout)
                try Task.checkCancellation()
                await self?.timeOutVoiceJoin(guildId: guildId, generation: generation)
            } catch {
                // Cancellation is the normal completion path after Discord
                // confirms the current generation.
            }
        }
    }

    private func scheduleVoiceLeaveDeadline(
        guildId: String,
        generation: VoiceGatewayHandshake.Generation
    ) {
        voiceHandshakeDeadlineTask?.cancel()
        let timeout = voiceHandshakeTimeout
        let sleep = voiceHandshakeSleep
        voiceHandshakeDeadlineTask = Task { [weak self] in
            do {
                try await sleep(timeout)
                try Task.checkCancellation()
                await self?.expireVoiceLeave(guildId: guildId, generation: generation)
            } catch {
                // A matching acknowledgement or Gateway close owns completion.
            }
        }
    }

    private func startUntrackedVoiceLeave(
        gateway: BotGatewayManager,
        guildID: String
    ) -> DiscordVoiceLeaveSignal {
        nextUntrackedVoiceLeaveID &+= 1
        let operation = DiscordUntrackedVoiceLeaveOperation(
            id: nextUntrackedVoiceLeaveID,
            guildID: guildID,
            signal: DiscordVoiceLeaveSignal()
        )
        untrackedVoiceLeaveOperation = operation

        voiceHandshakeDeadlineTask?.cancel()
        let timeout = voiceHandshakeTimeout
        let sleep = voiceHandshakeSleep
        voiceHandshakeDeadlineTask = Task { [weak self] in
            do {
                try await sleep(timeout)
                try Task.checkCancellation()
                await self?.expireUntrackedVoiceLeave(id: operation.id)
            } catch {
                // Send completion, disconnect, or Gateway failure owns cleanup.
            }
        }

        voiceLeaveSendTask?.cancel()
        voiceLeaveSendTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await gateway.updateVoiceState(
                payload: VoiceStateUpdate(
                    guildId: GuildSnowflake(guildID),
                    channelId: nil,
                    selfMute: true,
                    selfDeaf: true
                )
            )
            guard !Task.isCancelled else { return }
            await self?.completeUntrackedVoiceLeave(id: operation.id)
        }
        return operation.signal
    }

    private func completeUntrackedVoiceLeave(id: UInt64) async {
        guard let operation = untrackedVoiceLeaveOperation,
              operation.id == id
        else { return }
        untrackedVoiceLeaveOperation = nil
        voiceHandshakeDeadlineTask?.cancel()
        voiceHandshakeDeadlineTask = nil
        voiceLeaveSendTask = nil
        await operation.signal.resolve(.acknowledged)
    }

    private func expireUntrackedVoiceLeave(id: UInt64) async {
        guard let operation = untrackedVoiceLeaveOperation,
              operation.id == id
        else { return }
        untrackedVoiceLeaveOperation = nil
        voiceHandshakeDeadlineTask = nil
        voiceLeaveSendTask?.cancel()
        voiceLeaveSendTask = nil
        lifecycle.disconnect()
        eventTask?.cancel()
        eventTask = nil
        let gatewayToClose = gateway
        gateway = nil
        botUserId = nil
        voiceChannelId = nil
        voiceGuildId = nil
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.reset()
        await gatewayToClose?.disconnect()
        await operation.signal.resolve(.gatewayClosed)
        logger.warning("Discord force-leave send timed out; Gateway closed before reuse")
    }

    private func timeOutVoiceJoin(
        guildId: String,
        generation: VoiceGatewayHandshake.Generation
    ) async {
        guard case .cancelled = voiceGatewayHandshake.cancel(
            guildID: guildId,
            generation: generation
        ) else { return }
        voiceHandshakeDeadlineTask = nil
        voiceGatewayCredentials = nil
        logger.warning("Discord voice handshake timed out; leaving generation")
        _ = await initiateVoiceLeave(
            guildId: guildId,
            forceUntrackedPresence: false
        )
    }

    private func expireVoiceLeave(
        guildId: String,
        generation: VoiceGatewayHandshake.Generation
    ) async {
        guard voiceGatewayHandshake.expire(guildID: guildId, generation: generation) else { return }
        guard let signal = voiceLeaveCoordinator.complete(
            guildID: guildId,
            generation: generation
        ) else { return }

        // Discord does not echo our local generation in Voice State Updates.
        // After an unacknowledged leave expires, a late nil-channel event from
        // this generation could otherwise cancel a replacement generation on
        // the same Gateway event epoch. Close that epoch before releasing the
        // barrier; acknowledgement is the only same-connection success path.
        voiceLeaveSendTask?.cancel()
        voiceLeaveSendTask = nil
        voiceHandshakeDeadlineTask = nil
        lifecycle.disconnect()
        eventTask?.cancel()
        eventTask = nil
        let gatewayToClose = gateway
        gateway = nil
        botUserId = nil
        voiceChannelId = nil
        voiceGuildId = nil
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.reset()
        await gatewayToClose?.disconnect()
        await signal.resolve(.gatewayClosed)
        logger.warning("Discord voice leave acknowledgement timed out; Gateway closed before reuse")
    }

    private func completeVoiceHandshakeDeadline() {
        voiceHandshakeDeadlineTask?.cancel()
        voiceHandshakeDeadlineTask = nil
    }

    private func completeVoiceLeave(
        guildId: String,
        generation: VoiceGatewayHandshake.Generation,
        completion: DiscordVoiceLeaveCompletion
    ) {
        guard let signal = voiceLeaveCoordinator.complete(
            guildID: guildId,
            generation: generation
        ) else { return }
        voiceLeaveSendTask?.cancel()
        voiceLeaveSendTask = nil
        completeVoiceHandshakeDeadline()
        if voiceGatewayCredentials?.guildID == guildId {
            voiceGatewayCredentials = nil
        }
        if voiceGuildId == guildId {
            voiceGuildId = nil
            voiceChannelId = nil
        }
        Task { await signal.resolve(completion) }
    }

    private func resolveVoiceLeaveOperation(_ completion: DiscordVoiceLeaveCompletion) async {
        voiceLeaveSendTask?.cancel()
        voiceLeaveSendTask = nil
        guard let signal = voiceLeaveCoordinator.completeCurrent() else { return }
        await signal.resolve(completion)
    }

    private func resolveUntrackedVoiceLeaveOperation(
        _ completion: DiscordVoiceLeaveCompletion
    ) async {
        guard let operation = untrackedVoiceLeaveOperation else { return }
        untrackedVoiceLeaveOperation = nil
        voiceLeaveSendTask?.cancel()
        voiceLeaveSendTask = nil
        await operation.signal.resolve(completion)
    }

    /// Transfers ephemeral credentials to the internal media controller once.
    /// Keeping this package-internal prevents UI/server callers from retaining
    /// or displaying the Discord voice capability.
    func consumeVoiceGatewayCredentials(
        for generation: VoiceGatewayHandshake.Generation
    ) -> VoiceGatewayHandshake.Credentials? {
        guard voiceGatewayCredentials?.generation == generation else { return nil }
        defer { voiceGatewayCredentials = nil }
        return voiceGatewayCredentials
    }

    /// Receives the bot's main-Gateway voice-state dispatch. Public voice
    /// presence is updated only after Discord confirms the self state.
    public func handleVoiceStateUpdate(_ payload: VoiceState) {
        guard payload.user_id.rawValue == botUserId else { return }
        let guildId = payload.guild_id.rawValue
        let outcome = voiceGatewayHandshake.receive(
            .init(
                guildID: guildId,
                channelID: payload.channel_id?.rawValue,
                userID: payload.user_id.rawValue,
                sessionID: payload.session_id
            )
        )

        switch outcome {
        case .waiting, .ready:
            // The outbound opcode 4 request is not proof that Discord admitted
            // the bot to the channel. Publish presence only from Discord's
            // confirmed self Voice State Update.
            voiceGuildId = payload.channel_id == nil ? nil : guildId
            voiceChannelId = payload.channel_id?.rawValue
            if case .ready(let credentials) = outcome {
                voiceGatewayCredentials = credentials
                completeVoiceHandshakeDeadline()
            }
        case .cancelled(let generation):
            completeVoiceHandshakeDeadline()
            completeVoiceLeave(
                guildId: guildId,
                generation: generation,
                completion: .acknowledged
            )
            if voiceGatewayCredentials?.guildID == guildId {
                voiceGatewayCredentials = nil
            }
            if voiceGuildId == guildId {
                voiceGuildId = nil
                voiceChannelId = nil
            }
        case .ignored:
            if payload.channel_id == nil, voiceGuildId == guildId {
                voiceGatewayCredentials = nil
                voiceGuildId = nil
                voiceChannelId = nil
            }
        case .rejected:
            break
        }
    }

    func handleVoiceStateUpdate(
        _ payload: VoiceState,
        generation: DiscordGatewayLifecycle.Generation
    ) {
        guard lifecycle.isCurrent(generation) else { return }
        handleVoiceStateUpdate(payload)
    }

    /// Receives Discord's ephemeral Voice Gateway endpoint and token. The token
    /// remains actor-local until the future media transport consumes it.
    public func handleVoiceServerUpdate(_ payload: Gateway.VoiceServerUpdate) {
        let outcome = voiceGatewayHandshake.receive(
            .init(
                guildID: payload.guild_id.rawValue,
                endpoint: payload.endpoint,
                token: payload.token
            )
        )
        if case .ready(let credentials) = outcome {
            voiceGatewayCredentials = credentials
            completeVoiceHandshakeDeadline()
        } else if case .rejected(_, .emptyEndpoint) = outcome,
                  voiceGatewayCredentials?.guildID == payload.guild_id.rawValue
        {
            voiceGatewayCredentials = nil
        }
    }

    func handleVoiceServerUpdate(
        _ payload: Gateway.VoiceServerUpdate,
        generation: DiscordGatewayLifecycle.Generation
    ) {
        guard lifecycle.isCurrent(generation) else { return }
        handleVoiceServerUpdate(payload)
    }
}

public struct DiscordEventHooks: Sendable {
    public var onReady: @Sendable (_ userId: String) async -> Void
    public var onMessageCreate: @Sendable (_ message: Gateway.MessageCreate) async -> Void
    public var onInteractionCreate: @Sendable (_ interaction: Interaction) async -> Void

    public init(
        onReady: @escaping @Sendable (_ userId: String) async -> Void = { _ in },
        onMessageCreate: @escaping @Sendable (_ message: Gateway.MessageCreate) async -> Void = { _ in },
        onInteractionCreate: @escaping @Sendable (_ interaction: Interaction) async -> Void = { _ in }
    ) {
        self.onReady = onReady
        self.onMessageCreate = onMessageCreate
        self.onInteractionCreate = onInteractionCreate
    }
}
