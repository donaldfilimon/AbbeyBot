import Foundation

/// Correlates the two main-Gateway events Discord emits while a bot joins voice.
///
/// This type deliberately performs no I/O. Call `begin` before sending Gateway
/// opcode 4, then feed voice-state and voice-server events into the accumulator.
/// A completed credential set is emitted once per server allocation; the active
/// generation remains until leave so duplicate and failover events stay scoped.
public struct VoiceGatewayHandshake: Sendable {
    public struct Generation: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    public struct VoiceStateEvent: Sendable {
        public let guildID: String?
        public let channelID: String?
        public let userID: String
        public let sessionID: String

        public init(guildID: String?, channelID: String?, userID: String, sessionID: String) {
            self.guildID = guildID
            self.channelID = channelID
            self.userID = userID
            self.sessionID = sessionID
        }
    }

    public struct VoiceServerEvent: Sendable {
        public let guildID: String
        public let endpoint: String?
        public let token: String

        public init(guildID: String, endpoint: String?, token: String) {
            self.guildID = guildID
            self.endpoint = endpoint
            self.token = token
        }
    }

    /// Ephemeral capability data used to identify on Discord's Voice Gateway.
    /// It is intentionally not Codable, persistable, or printable with any
    /// session, endpoint, or token capability data.
    public struct Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let guildID: String
        public let channelID: String
        public let userID: String
        public let sessionID: String
        public let endpoint: String
        public let token: String
        public let generation: Generation

        public var description: String {
            "VoiceGatewayCredentials(<redacted>)"
        }

        public var debugDescription: String { description }

        /// Keep `dump` and other Mirror-based diagnostics from traversing the
        /// stored session, endpoint, and token capability fields.
        public var customMirror: Mirror {
            Mirror(self, children: ["credentials": "<redacted>"], displayStyle: .struct)
        }
    }

    public enum Rejection: Equatable, Sendable {
        case emptySessionID
        case emptyEndpoint
        case emptyToken
    }

    public enum Outcome: Sendable {
        case ignored
        case waiting(Generation)
        case cancelled(Generation)
        case rejected(Generation, Rejection)
        case ready(Credentials)
    }

    private struct Pending: Sendable {
        let guildID: String
        let channelID: String
        let userID: String
        let generation: Generation
        var sessionID: String?
        var endpoint: String?
        var token: String?
        var hasEmittedCredentials = false
    }

    private struct Leaving: Sendable {
        let userID: String
        let generation: Generation
    }

    private var nextGeneration: UInt64 = 0
    private var pendingByGuild: [String: Pending] = [:]
    private var leavingByGuild: [String: Leaving] = [:]

    public init() {}

    /// Starts a join only when no generation is active or awaiting leave.
    /// Call this before sending the main-Gateway voice-state update.
    @discardableResult
    public mutating func begin(guildID: String, channelID: String, userID: String) -> Generation? {
        // AbbeyBot owns one voice generation at a time. In particular, never
        // replace a same-guild request: Discord's server event has no channel or
        // client nonce, so a late event cannot otherwise be distinguished from
        // the replacement request.
        guard pendingByGuild.isEmpty, leavingByGuild.isEmpty else { return nil }
        nextGeneration &+= 1
        let generation = Generation(value: nextGeneration)
        pendingByGuild[guildID] = Pending(
            guildID: guildID,
            channelID: channelID,
            userID: userID,
            generation: generation
        )
        return generation
    }

    /// Cancels only the currently active generation for the supplied guild.
    @discardableResult
    public mutating func cancel(guildID: String, generation: Generation? = nil) -> Outcome {
        guard let pending = pendingByGuild[guildID] else { return .ignored }
        if let generation, generation != pending.generation { return .ignored }
        pendingByGuild[guildID] = nil
        leavingByGuild[guildID] = Leaving(userID: pending.userID, generation: pending.generation)
        return .cancelled(pending.generation)
    }

    public mutating func receive(_ event: VoiceStateEvent) -> Outcome {
        if let guildID = event.guildID,
           let leaving = leavingByGuild[guildID],
           event.userID == leaving.userID,
           event.channelID == nil
        {
            leavingByGuild[guildID] = nil
            return .cancelled(leaving.generation)
        }

        guard
            let guildID = event.guildID,
            var pending = pendingByGuild[guildID],
            event.userID == pending.userID
        else {
            return .ignored
        }

        // A matching self voice-state with no channel is Discord's leave signal.
        guard let channelID = event.channelID else {
            pendingByGuild[guildID] = nil
            return .cancelled(pending.generation)
        }
        guard channelID == pending.channelID else { return .ignored }
        guard !event.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(pending.generation, .emptySessionID)
        }

        if pending.sessionID != event.sessionID {
            // A changed session must not be paired with capability data emitted
            // for the prior session.
            if pending.hasEmittedCredentials {
                pending.endpoint = nil
                pending.token = nil
            }
            pending.sessionID = event.sessionID
            pending.hasEmittedCredentials = false
        }
        pendingByGuild[guildID] = pending
        return completeIfReady(guildID: guildID)
    }

    public mutating func receive(_ event: VoiceServerEvent) -> Outcome {
        guard var pending = pendingByGuild[event.guildID] else { return .ignored }
        guard let endpoint = event.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty else {
            // Discord uses a null endpoint to announce that the allocation has
            // gone away. Invalidate the entire server half and wait for a fresh
            // allocation rather than reusing the old token.
            pending.endpoint = nil
            pending.token = nil
            pending.hasEmittedCredentials = false
            pendingByGuild[event.guildID] = pending
            return .rejected(pending.generation, .emptyEndpoint)
        }
        guard !event.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(pending.generation, .emptyToken)
        }

        if pending.hasEmittedCredentials,
           pending.endpoint == endpoint,
           pending.token == event.token
        {
            return .ignored
        }

        pending.endpoint = endpoint
        pending.token = event.token
        pending.hasEmittedCredentials = false
        pendingByGuild[event.guildID] = pending
        return completeIfReady(guildID: event.guildID)
    }

    public func generation(for guildID: String) -> Generation? {
        pendingByGuild[guildID]?.generation
    }

    /// Releases a stalled join or leave barrier only when it still belongs to
    /// the generation that scheduled the deadline. Discord does not attach a
    /// client nonce to these Gateway events, so callers must never expire a
    /// newer generation with an older timer.
    @discardableResult
    public mutating func expire(guildID: String, generation: Generation) -> Bool {
        if pendingByGuild[guildID]?.generation == generation {
            pendingByGuild[guildID] = nil
            return true
        }
        if leavingByGuild[guildID]?.generation == generation {
            leavingByGuild[guildID] = nil
            return true
        }
        return false
    }

    /// Drops all capability-bearing state while preserving the monotonic
    /// generation counter so callbacks from before a disconnect remain stale.
    public mutating func reset() {
        pendingByGuild.removeAll(keepingCapacity: false)
        leavingByGuild.removeAll(keepingCapacity: false)
    }

    private mutating func completeIfReady(guildID: String) -> Outcome {
        guard let pending = pendingByGuild[guildID] else { return .ignored }
        guard
            let sessionID = pending.sessionID,
            let endpoint = pending.endpoint,
            let token = pending.token
        else {
            return .waiting(pending.generation)
        }

        if pending.hasEmittedCredentials { return .ignored }

        var updated = pending
        updated.hasEmittedCredentials = true
        pendingByGuild[guildID] = updated
        return .ready(
            Credentials(
                guildID: updated.guildID,
                channelID: updated.channelID,
                userID: updated.userID,
                sessionID: sessionID,
                endpoint: endpoint,
                token: token,
                generation: updated.generation
            )
        )
    }
}
