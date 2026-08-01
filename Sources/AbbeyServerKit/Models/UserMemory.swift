import Fluent
import Foundation
import Vapor

public final class UserMemory: Model, Content, @unchecked Sendable {
    public static let schema = "user_memories"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "composite_key")
    public var compositeKey: String

    @Field(key: "discord_user_id")
    public var discordUserId: String

    @Field(key: "guild_id")
    public var guildId: String

    @Field(key: "facts")
    public var facts: [String]

    @Field(key: "reputation")
    public var reputation: Double

    @Field(key: "interaction_count")
    public var interactionCount: Int

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    /// Original server clock for rows mirrored by CLI `/sync pull`.
    @OptionalField(key: "source_updated_at")
    public var sourceUpdatedAt: Date?

    /// Soft-delete tombstone for desktop↔server sync. Nil means live; non-nil means the
    /// row should be removed on pull (and excluded from full-list endpoints). Cleared if
    /// a later `remember` / channel bump resurrects the row.
    @OptionalField(key: "deleted_at")
    public var deletedAt: Date?

    public init() {}

    public init(
        id: UUID? = nil,
        discordUserId: String,
        guildId: String,
        facts: [String] = [],
        reputation: Double = 0.5,
        interactionCount: Int = 0
    ) {
        self.id = id
        self.compositeKey = "\(guildId):\(discordUserId)"
        self.discordUserId = discordUserId
        self.guildId = guildId
        self.facts = facts
        self.reputation = reputation
        self.interactionCount = interactionCount
    }
}
