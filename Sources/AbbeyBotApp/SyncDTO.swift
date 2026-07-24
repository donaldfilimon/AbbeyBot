import Foundation

/// Fluent JSON list shapes for desktop sync pull (camelCase).
///
/// Owned next to `SyncPull`, not the HTTP client — these are the sync contract.
enum SyncDTO {
    struct User: Decodable, Sendable {
        var id: UUID?
        var compositeKey: String
        var discordUserId: String
        var guildId: String
        var facts: [String]
        var reputation: Double
        var interactionCount: Int
        var updatedAt: Date?
    }

    struct Channel: Decodable, Sendable {
        var id: UUID?
        var compositeKey: String
        var channelId: String
        var guildId: String
        var summary: String
        var messageCount: Int
        var updatedAt: Date?
    }

    struct Message: Decodable, Sendable {
        var id: UUID?
        var discordMessageId: String
        var channelId: String
        var guildId: String
        var authorId: String
        var content: String
        var createdAt: Date?
    }

    /// Insert-if-missing keyed by Fluent `id` (`serverId` locally). Rows without `id` are skipped.
    struct Reputation: Decodable, Sendable {
        var id: UUID?
        var userId: String
        var guildId: String
        var delta: Double
        var reason: String
        var createdAt: Date?
    }

    /// Insert-if-missing keyed by Fluent `id` (`serverId` locally). Rows without `id` are skipped.
    struct Interaction: Decodable, Sendable {
        var id: UUID?
        var commandName: String
        var userId: String
        var guildId: String
        var succeeded: Bool
        var latencyMs: Double
        var createdAt: Date?
    }

    struct Equity: Decodable, Sendable {
        var id: UUID?
        var symbol: String
        var thesisSummary: String
        var syntheticScore: Double
        var factorBreakdown: [String: Double]
        var generatedAt: Date?
    }
}
