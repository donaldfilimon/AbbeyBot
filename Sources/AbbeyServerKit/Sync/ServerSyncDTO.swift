import Foundation

/// Decodable shapes for the server's list endpoints (`GET /api/users|channels|messages|
/// reputation|interactions|equity`), as consumed by a *pulling* client. The desktop app keeps
/// its own copy next to `SyncPull` (SwiftData side); this is the Fluent-side mirror used by
/// the CLI's `/sync pull`. Field names are the camelCase property names Vapor encodes; dates
/// are ISO 8601.
public enum ServerSyncDTO {
    public struct User: Decodable, Sendable {
        public var id: UUID?
        public var compositeKey: String
        public var discordUserId: String
        public var guildId: String
        public var facts: [String]
        public var reputation: Double
        public var interactionCount: Int
        public var updatedAt: Date?
        /// Soft-delete tombstone. Non-nil means the puller should remove its local row.
        public var deletedAt: Date?

        public init(
            id: UUID? = nil,
            compositeKey: String,
            discordUserId: String,
            guildId: String,
            facts: [String],
            reputation: Double,
            interactionCount: Int,
            updatedAt: Date? = nil,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.compositeKey = compositeKey
            self.discordUserId = discordUserId
            self.guildId = guildId
            self.facts = facts
            self.reputation = reputation
            self.interactionCount = interactionCount
            self.updatedAt = updatedAt
            self.deletedAt = deletedAt
        }
    }

    public struct Channel: Decodable, Sendable {
        public var id: UUID?
        public var compositeKey: String
        public var channelId: String
        public var guildId: String
        public var summary: String
        public var messageCount: Int
        public var updatedAt: Date?
        public var deletedAt: Date?

        public init(
            id: UUID? = nil,
            compositeKey: String,
            channelId: String,
            guildId: String,
            summary: String,
            messageCount: Int,
            updatedAt: Date? = nil,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.compositeKey = compositeKey
            self.channelId = channelId
            self.guildId = guildId
            self.summary = summary
            self.messageCount = messageCount
            self.updatedAt = updatedAt
            self.deletedAt = deletedAt
        }
    }

    public struct Message: Decodable, Sendable {
        public var id: UUID?
        public var discordMessageId: String
        public var channelId: String
        public var guildId: String
        public var authorId: String
        public var content: String
        public var createdAt: Date?
        public var deletedAt: Date?

        public init(
            id: UUID? = nil,
            discordMessageId: String,
            channelId: String,
            guildId: String,
            authorId: String,
            content: String,
            createdAt: Date? = nil,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.discordMessageId = discordMessageId
            self.channelId = channelId
            self.guildId = guildId
            self.authorId = authorId
            self.content = content
            self.createdAt = createdAt
            self.deletedAt = deletedAt
        }
    }

    /// Insert-if-missing keyed by Fluent `id`; rows without `id` are skipped.
    public struct Reputation: Decodable, Sendable {
        public var id: UUID?
        public var userId: String
        public var guildId: String
        public var delta: Double
        public var reason: String
        public var createdAt: Date?
        public var deletedAt: Date?

        public init(
            id: UUID? = nil,
            userId: String,
            guildId: String,
            delta: Double,
            reason: String,
            createdAt: Date? = nil,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.userId = userId
            self.guildId = guildId
            self.delta = delta
            self.reason = reason
            self.createdAt = createdAt
            self.deletedAt = deletedAt
        }
    }

    /// Insert-if-missing keyed by Fluent `id`; rows without `id` are skipped.
    public struct Interaction: Decodable, Sendable {
        public var id: UUID?
        public var commandName: String
        public var userId: String
        public var guildId: String
        public var succeeded: Bool
        public var latencyMs: Double
        public var createdAt: Date?
        public var deletedAt: Date?

        public init(
            id: UUID? = nil,
            commandName: String,
            userId: String,
            guildId: String,
            succeeded: Bool,
            latencyMs: Double,
            createdAt: Date? = nil,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.commandName = commandName
            self.userId = userId
            self.guildId = guildId
            self.succeeded = succeeded
            self.latencyMs = latencyMs
            self.createdAt = createdAt
            self.deletedAt = deletedAt
        }
    }

    public struct Equity: Decodable, Sendable {
        public var id: UUID?
        public var symbol: String
        public var thesisSummary: String
        public var syntheticScore: Double
        public var factorBreakdown: [String: Double]
        public var generatedAt: Date?
        public var deletedAt: Date?

        public init(
            id: UUID? = nil,
            symbol: String,
            thesisSummary: String,
            syntheticScore: Double,
            factorBreakdown: [String: Double],
            generatedAt: Date? = nil,
            deletedAt: Date? = nil
        ) {
            self.id = id
            self.symbol = symbol
            self.thesisSummary = thesisSummary
            self.syntheticScore = syntheticScore
            self.factorBreakdown = factorBreakdown
            self.generatedAt = generatedAt
            self.deletedAt = deletedAt
        }
    }
}
