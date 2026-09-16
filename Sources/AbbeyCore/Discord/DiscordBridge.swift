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

private struct DiscordDetachedGatewayState: Sendable {
    let gateway: (any DiscordGatewayDriver)?
    let trackedLeaveSignal: DiscordVoiceLeaveSignal?
    let untrackedLeaveSignal: DiscordVoiceLeaveSignal?
}

/// Atomic snapshot of confirmed self voice-state presence. Reading
/// `voiceChannelId`/`voiceSelfMute`/`voiceSelfDeaf` as three separate actor
/// hops can tear across a concurrent leave; `DiscordBridge.voicePresenceState()`
/// returns all three from a single actor-isolated read instead.
public struct DiscordVoicePresenceState: Equatable, Sendable {
    public let confirmedInChannel: Bool
    public let selfMute: Bool
    public let selfDeaf: Bool

    public init(confirmedInChannel: Bool, selfMute: Bool, selfDeaf: Bool) {
        self.confirmedInChannel = confirmedInChannel
        self.selfMute = selfMute
        self.selfDeaf = selfDeaf
    }
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
    /// Discord-confirmed self `self_mute`/`self_deaf` presence bits from the last
    /// self `VOICE_STATE_UPDATE` for the tracked channel. Presence only — there is
    /// no Opus/UDP audio yet, so these flags change what other members observe,
    /// not what is heard.
    public private(set) var voiceSelfMute = false
    public private(set) var voiceSelfDeaf = false
    /// Ephemeral main-Gateway participant location facts. Raw user IDs never
    /// leave this actor; callers receive only SHA-256 digests and a count.
    private var voiceParticipantChannelByGuildUser: [String: String] = [:]
    /// Guilds become complete only after GUILD_CREATE supplies the authoritative
    /// initial voice-state set. If the bounded table overflows, completeness is
    /// revoked until a fresh GUILD_CREATE/reconnect replaces the snapshot.
    private var completeVoiceParticipantGuilds = Set<String>()
    private var incompleteVoiceParticipantGuilds = Set<String>()
    private static let maximumTrackedVoiceParticipants = 2_048
    private struct ParticipantSubscription {
        var guildID: String
        var channelID: String
        var continuation: AsyncStream<DiscordVoiceParticipantSnapshot>.Continuation
    }
    private var participantSubscriptions: [UUID: ParticipantSubscription] = [:]

    private var gateway: (any DiscordGatewayDriver)?
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
    private let gatewayFactory: DiscordGatewayDriverFactory
    private let logger = Logger(label: "AbbeyBot.DiscordBridge")

    public init() {
        self.voiceHandshakeTimeout = .seconds(30)
        self.voiceHandshakeSleep = { duration in
            try await Task.sleep(for: duration)
        }
        self.gatewayFactory = DiscordGatewayDrivers.production
    }

    init(
        voiceHandshakeTimeout: Duration,
        voiceHandshakeSleep: @escaping @Sendable (Duration) async throws -> Void,
        gatewayFactory: @escaping DiscordGatewayDriverFactory = DiscordGatewayDrivers.production
    ) {
        self.voiceHandshakeTimeout = max(.milliseconds(1), voiceHandshakeTimeout)
        self.voiceHandshakeSleep = voiceHandshakeSleep
        self.gatewayFactory = gatewayFactory
    }

    public var client: (any DiscordClient)? {
        gateway?.client
    }

    /// True when a live BotGatewayManager is held (false under dry-run).
    public var hasGateway: Bool {
        gateway != nil
    }

    /// Re-fetches the guild and member immediately before a desktop-approved
    /// Discord effect. Interaction permission fields are only a creation-time
    /// fact; they must never be reused as current authorization evidence.
    public func currentManagerAuthorization(guildID: String, userID: String) async -> Bool {
        guard lifecycle.state == .connected,
              !guildID.isEmpty,
              guildID != "DM",
              !userID.isEmpty,
              let client = gateway?.client
        else { return false }

        do {
            let guildSnowflake = GuildSnowflake(guildID)
            let userSnowflake = UserSnowflake(userID)
            async let guildResponse = client.getGuild(id: guildSnowflake)
            async let memberResponse = client.getGuildMember(
                guildId: guildSnowflake,
                userId: userSnowflake
            )
            let guild = try await guildResponse.decode()
            let member = try await memberResponse.decode()
            if guild.owner_id == userSnowflake { return true }
            let memberRoleIDs = Set(member.roles)
            let effectiveRoles = guild.roles.filter {
                $0.id == guild.id || memberRoleIDs.contains($0.id)
            }
            if effectiveRoles.contains(where: { $0.permissions.contains(.administrator) }) {
                return true
            }
            return effectiveRoles.contains {
                $0.permissions.contains(.manageGuild) || $0.permissions.contains(.moderateMembers)
            }
        } catch {
            logger.warning("Discord permission revalidation failed closed: \(error.localizedDescription)")
            return false
        }
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

        let driver = await gatewayFactory(
            .init(token: token, presenceActivityName: presenceActivityName)
        )
        guard lifecycle.isCurrent(generation), state == .connecting else {
            await driver.disconnect()
            return
        }
        self.gateway = driver

        eventTask = Task { [weak self] in
            do {
                for try await input in await driver.makeEvents() {
                    guard !Task.isCancelled, let self else { return }
                    switch input {
                    case .gateway(let event):
                        await self.handleGatewayEvent(event, hooks: hooks, generation: generation)
                    case .barrier(let barrier):
                        await barrier.resolve()
                    }
                }
                guard !Task.isCancelled else { return }
                await self?.noteEventStreamEnded(generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.noteEventStreamFailed(generation: generation)
            }
        }

        await driver.connect()
    }

    public func disconnect() async {
        let generation = lifecycle.generation
        // Keep consuming Gateway events while the bounded voice-leave barrier
        // waits for Discord's self Voice State Update acknowledgement.
        if let guildId = voiceGuildId ?? voiceGatewayHandshake.activeGuildID {
            _ = await leaveVoiceAndWaitForAcknowledgement(guildId: guildId)
        }
        // A voice timeout may have closed this epoch and allowed a replacement
        // connection to start while this leave waiter was suspended.
        guard lifecycle.isCurrent(generation) else { return }
        let detached = detachGatewayState(disconnectLifecycle: true)
        await finishGatewayTeardown(detached, completion: .gatewayClosed)
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
        let detached = detachGatewayState(disconnectLifecycle: false)
        await finishGatewayTeardown(detached, completion: .gatewayClosed)
        logger.error("Discord bridge failure: \(DiscordGatewayLifecycle.streamEndedError)")
    }

    private func noteEventStreamFailed(generation: DiscordGatewayLifecycle.Generation) async {
        guard lifecycle.eventStreamFailed(generation: generation) else { return }
        let detached = detachGatewayState(disconnectLifecycle: false)
        await finishGatewayTeardown(detached, completion: .gatewayClosed)
        logger.error("Discord bridge failure: \(DiscordGatewayLifecycle.streamFailedError)")
    }

    private func detachGatewayState(
        disconnectLifecycle: Bool
    ) -> DiscordDetachedGatewayState {
        if disconnectLifecycle {
            lifecycle.disconnect()
        }
        voiceHandshakeDeadlineTask?.cancel()
        voiceHandshakeDeadlineTask = nil
        voiceLeaveSendTask?.cancel()
        voiceLeaveSendTask = nil
        eventTask?.cancel()
        eventTask = nil
        let detached = DiscordDetachedGatewayState(
            gateway: gateway,
            trackedLeaveSignal: voiceLeaveCoordinator.completeCurrent(),
            untrackedLeaveSignal: untrackedVoiceLeaveOperation?.signal
        )
        gateway = nil
        untrackedVoiceLeaveOperation = nil
        botUserId = nil
        clearEphemeralParticipants()
        voiceChannelId = nil
        voiceGuildId = nil
        voiceSelfMute = false
        voiceSelfDeaf = false
        voiceGatewayCredentials = nil
        voiceGatewayHandshake.reset()
        return detached
    }

    private func finishGatewayTeardown(
        _ detached: DiscordDetachedGatewayState,
        completion: DiscordVoiceLeaveCompletion
    ) async {
        await detached.gateway?.disconnect()
        await detached.trackedLeaveSignal?.resolve(completion)
        await detached.untrackedLeaveSignal?.resolve(completion)
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
        gateway: any DiscordGatewayDriver,
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
        clearEphemeralParticipants()
        voiceChannelId = nil
        voiceGuildId = nil
        voiceSelfMute = false
        voiceSelfDeaf = false
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
        clearEphemeralParticipants()
        voiceChannelId = nil
        voiceGuildId = nil
        voiceSelfMute = false
        voiceSelfDeaf = false
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
        updateEphemeralParticipantState(payload)
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
            voiceSelfMute = payload.channel_id == nil ? false : payload.self_mute
            voiceSelfDeaf = payload.channel_id == nil ? false : payload.self_deaf
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
                voiceSelfMute = false
                voiceSelfDeaf = false
            }
        case .ignored:
            if payload.channel_id == nil, voiceGuildId == guildId {
                voiceGatewayCredentials = nil
                voiceGuildId = nil
                voiceChannelId = nil
                voiceSelfMute = false
                voiceSelfDeaf = false
            } else if guildId == voiceGuildId, let confirmedChannelId = payload.channel_id?.rawValue {
                // No join/leave handshake is active — this is Discord's
                // confirmed self Voice State for the guild we are in: either
                // an echo of a presence-only self-mute/self-deaf update, or a
                // server-side move to another channel. Track the confirmed
                // channel either way, so a later mute/deafen opcode 4 targets
                // the channel the bot is actually in rather than moving it
                // back to a channel Discord already took it out of.
                voiceChannelId = confirmedChannelId
                voiceSelfMute = payload.self_mute
                voiceSelfDeaf = payload.self_deaf
            }
        case .rejected:
            break
        }
    }

    /// Single actor-isolated read of confirmed channel presence plus self-mute/
    /// self-deaf, so callers never observe a torn combination across a
    /// concurrent leave (e.g. `confirmedInChannel: true` with stale flags).
    public func voicePresenceState() -> DiscordVoicePresenceState {
        DiscordVoicePresenceState(
            confirmedInChannel: voiceChannelId != nil,
            selfMute: voiceSelfMute,
            selfDeaf: voiceSelfDeaf
        )
    }

    /// Content-free participant snapshot for the operator consent gate. The
    /// bot itself is excluded; every human participant is represented only by
    /// a stable digest for comparison across one process lifetime.
    public func voiceParticipantSnapshot(
        guildID: String,
        channelID: String
    ) -> DiscordVoiceParticipantSnapshot {
        let guildPrefix = guildID + "\u{1f}"
        let identities = voiceParticipantChannelByGuildUser.compactMap { key, value -> String? in
            guard value == channelID, key.hasPrefix(guildPrefix) else { return nil }
            let userID = String(key.dropFirst(guildPrefix.count))
            return userID == botUserId ? nil : userID
        }
        let digests = Set(identities.map(LiveMediaQualificationCoordinator.participantDigest))
        let isComplete = completeVoiceParticipantGuilds.contains(guildID)
            && !incompleteVoiceParticipantGuilds.contains(guildID)
        return DiscordVoiceParticipantSnapshot(
            count: digests.count,
            participantDigests: digests,
            isComplete: isComplete
        )
    }

    /// Content-free, buffering-newest participant changes for immediate
    /// consent invalidation. Raw identities stay actor-local; cancellation
    /// removes the continuation so a closed operator workspace cannot leak.
    public func voiceParticipantSnapshots(
        guildID: String,
        channelID: String
    ) -> AsyncStream<DiscordVoiceParticipantSnapshot> {
        let id = UUID()
        let pair = AsyncStream<DiscordVoiceParticipantSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        participantSubscriptions[id] = ParticipantSubscription(
            guildID: guildID,
            channelID: channelID,
            continuation: pair.continuation
        )
        pair.continuation.onTermination = { _ in
            Task { await self.removeParticipantSubscription(id) }
        }
        pair.continuation.yield(voiceParticipantSnapshot(guildID: guildID, channelID: channelID))
        return pair.stream
    }

    private func updateEphemeralParticipantState(_ payload: VoiceState) {
        let guildID = payload.guild_id.rawValue
        let userID = payload.user_id.rawValue
        let key = guildID + "\u{1f}" + userID
        let previousChannelID = voiceParticipantChannelByGuildUser[key]
        if let channelID = payload.channel_id?.rawValue {
            guard voiceParticipantChannelByGuildUser[key] != nil
                    || voiceParticipantChannelByGuildUser.count
                        < Self.maximumTrackedVoiceParticipants
            else {
                incompleteVoiceParticipantGuilds.insert(guildID)
                publishParticipantSnapshotsForGuild(guildID)
                return
            }
            voiceParticipantChannelByGuildUser[key] = channelID
        } else {
            voiceParticipantChannelByGuildUser.removeValue(forKey: key)
        }
        publishParticipantSnapshots(guildID: guildID, channelIDs: [previousChannelID, payload.channel_id?.rawValue])
    }

    /// Replaces one guild's incremental cache with the complete voice-state set
    /// delivered in GUILD_CREATE. This is internal so lifecycle tests can prove
    /// the completeness transition without constructing Discord's full guild DTO.
    func installInitialVoiceStates(
        guildID: String,
        states: [(userID: String, channelID: String?)]
    ) {
        let prefix = guildID + "\u{1f}"
        let oldChannels = voiceParticipantChannelByGuildUser.compactMap { key, channel in
            key.hasPrefix(prefix) ? channel : nil
        }
        voiceParticipantChannelByGuildUser = voiceParticipantChannelByGuildUser.filter {
            !$0.key.hasPrefix(prefix)
        }
        completeVoiceParticipantGuilds.remove(guildID)
        incompleteVoiceParticipantGuilds.remove(guildID)

        var affectedChannels = Set(oldChannels)
        for state in states {
            guard !state.userID.isEmpty else {
                incompleteVoiceParticipantGuilds.insert(guildID)
                continue
            }
            guard let channelID = state.channelID, !channelID.isEmpty else { continue }
            affectedChannels.insert(channelID)
            let key = prefix + state.userID
            guard voiceParticipantChannelByGuildUser[key] != nil
                    || voiceParticipantChannelByGuildUser.count
                        < Self.maximumTrackedVoiceParticipants
            else {
                incompleteVoiceParticipantGuilds.insert(guildID)
                continue
            }
            voiceParticipantChannelByGuildUser[key] = channelID
        }
        if !incompleteVoiceParticipantGuilds.contains(guildID) {
            completeVoiceParticipantGuilds.insert(guildID)
        }
        publishParticipantSnapshots(
            guildID: guildID,
            channelIDs: affectedChannels.map(Optional.some)
        )
        publishParticipantSnapshotsForGuild(guildID)
    }

    func handleGuildCreate(
        _ payload: Gateway.GuildCreate,
        generation: DiscordGatewayLifecycle.Generation
    ) {
        guard lifecycle.isCurrent(generation) else { return }
        installInitialVoiceStates(
            guildID: payload.id.rawValue,
            states: payload.voice_states.map {
                (userID: $0.user_id.rawValue, channelID: $0.channel_id?.rawValue)
            }
        )
    }

    func handleGuildDelete(
        _ payload: UnavailableGuild,
        generation: DiscordGatewayLifecycle.Generation
    ) {
        guard lifecycle.isCurrent(generation) else { return }
        let guildID = payload.id.rawValue
        let prefix = guildID + "\u{1f}"
        voiceParticipantChannelByGuildUser = voiceParticipantChannelByGuildUser.filter {
            !$0.key.hasPrefix(prefix)
        }
        completeVoiceParticipantGuilds.remove(guildID)
        incompleteVoiceParticipantGuilds.insert(guildID)
        publishParticipantSnapshotsForGuild(guildID)
    }

    private func removeParticipantSubscription(_ id: UUID) {
        participantSubscriptions.removeValue(forKey: id)
    }

    private func publishParticipantSnapshots(guildID: String, channelIDs: [String?]) {
        let affected = Set(channelIDs.compactMap { $0 })
        guard !affected.isEmpty else { return }
        for subscription in participantSubscriptions.values
        where subscription.guildID == guildID && affected.contains(subscription.channelID) {
            subscription.continuation.yield(
                voiceParticipantSnapshot(
                    guildID: subscription.guildID,
                    channelID: subscription.channelID
                )
            )
        }
    }

    private func publishParticipantSnapshotsForGuild(_ guildID: String) {
        for subscription in participantSubscriptions.values where subscription.guildID == guildID {
            subscription.continuation.yield(
                voiceParticipantSnapshot(
                    guildID: subscription.guildID,
                    channelID: subscription.channelID
                )
            )
        }
    }

    private func clearEphemeralParticipants() {
        voiceParticipantChannelByGuildUser.removeAll(keepingCapacity: false)
        completeVoiceParticipantGuilds.removeAll(keepingCapacity: false)
        incompleteVoiceParticipantGuilds.removeAll(keepingCapacity: false)
        for subscription in participantSubscriptions.values {
            subscription.continuation.yield(.init(
                count: 0,
                participantDigests: [],
                isComplete: false
            ))
        }
    }

    /// Updates self-mute/self-deaf presence for the already-confirmed voice
    /// channel without requesting a new gateway pair or Voice Gateway session.
    /// Presence only: there is no Opus/UDP audio to silence yet, so this only
    /// changes what Discord and other members observe about the bot's voice
    /// state. The tracked `voiceSelfMute`/`voiceSelfDeaf` values update only
    /// once Discord echoes the change back through `handleVoiceStateUpdate`.
    @discardableResult
    public func updateVoiceMuteState(selfMute: Bool, selfDeaf: Bool) async -> VoiceUpdateResult {
        guard let gateway else { return .gatewayUnavailable }
        guard let guildId = voiceGuildId, let channelId = voiceChannelId else {
            return .invalidIdentifiers
        }
        await gateway.updateVoiceState(
            payload: VoiceStateUpdate(
                guildId: GuildSnowflake(guildId),
                channelId: ChannelSnowflake(channelId),
                selfMute: selfMute,
                selfDeaf: selfDeaf
            )
        )
        return .requested
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
    public var onMessageReactionAdd: @Sendable (_ reaction: Gateway.MessageReactionAdd) async -> Void
    public var onMessageDelete: @Sendable (_ deleted: Gateway.MessageDelete) async -> Void
    public var onMessageDeleteBulk: @Sendable (_ deleted: Gateway.MessageDeleteBulk) async -> Void

    public init(
        onReady: @escaping @Sendable (_ userId: String) async -> Void = { _ in },
        onMessageCreate: @escaping @Sendable (_ message: Gateway.MessageCreate) async -> Void = { _ in },
        onInteractionCreate: @escaping @Sendable (_ interaction: Interaction) async -> Void = { _ in },
        onMessageReactionAdd: @escaping @Sendable (_ reaction: Gateway.MessageReactionAdd) async -> Void = { _ in },
        onMessageDelete: @escaping @Sendable (_ deleted: Gateway.MessageDelete) async -> Void = { _ in },
        onMessageDeleteBulk: @escaping @Sendable (_ deleted: Gateway.MessageDeleteBulk) async -> Void = { _ in }
    ) {
        self.onReady = onReady
        self.onMessageCreate = onMessageCreate
        self.onInteractionCreate = onInteractionCreate
        self.onMessageReactionAdd = onMessageReactionAdd
        self.onMessageDelete = onMessageDelete
        self.onMessageDeleteBulk = onMessageDeleteBulk
    }
}
