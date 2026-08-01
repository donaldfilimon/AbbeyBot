import Foundation

/// Correlates the two main-Gateway events Discord emits while a bot joins voice.
///
/// This type deliberately performs no I/O. Call `begin` before sending Gateway
/// opcode 4, then feed voice-state and voice-server events into the accumulator.
/// A completed credential set is emitted once and removed from pending state.
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
    /// It is intentionally not Codable, persistable, or printable with its token.
    public struct Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let guildID: String
        public let channelID: String
        public let userID: String
        public let sessionID: String
        public let endpoint: String
        public let token: String
        public let generation: Generation

        public var description: String {
            "VoiceGatewayCredentials(guildID: \(guildID), channelID: \(channelID), "
                + "userID: \(userID), sessionID: \(sessionID), endpoint: \(endpoint), token: <redacted>)"
        }

        public var debugDescription: String { description }
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
    }

    private var nextGeneration: UInt64 = 0
    private var pendingByGuild: [String: Pending] = [:]

    public init() {}

    /// Starts (or replaces) the pending join for a guild.
    /// Call this before sending the main-Gateway voice-state update.
    @discardableResult
    public mutating func begin(guildID: String, channelID: String, userID: String) -> Generation {
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
        return .cancelled(pending.generation)
    }

    public mutating func receive(_ event: VoiceStateEvent) -> Outcome {
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

        pending.sessionID = event.sessionID
        pendingByGuild[guildID] = pending
        return completeIfReady(guildID: guildID)
    }

    public mutating func receive(_ event: VoiceServerEvent) -> Outcome {
        guard var pending = pendingByGuild[event.guildID] else { return .ignored }
        guard let endpoint = event.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty else {
            return .rejected(pending.generation, .emptyEndpoint)
        }
        guard !event.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(pending.generation, .emptyToken)
        }

        pending.endpoint = endpoint
        pending.token = event.token
        pendingByGuild[event.guildID] = pending
        return completeIfReady(guildID: event.guildID)
    }

    public func generation(for guildID: String) -> Generation? {
        pendingByGuild[guildID]?.generation
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

        pendingByGuild[guildID] = nil
        return .ready(
            Credentials(
                guildID: pending.guildID,
                channelID: pending.channelID,
                userID: pending.userID,
                sessionID: sessionID,
                endpoint: endpoint,
                token: token,
                generation: pending.generation
            )
        )
    }
}
