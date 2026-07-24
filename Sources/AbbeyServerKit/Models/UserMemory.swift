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
