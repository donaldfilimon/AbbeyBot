import Fluent
import Foundation
import Vapor

final class UserMemory: Model, Content, @unchecked Sendable {
    static let schema = "user_memories"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "composite_key")
    var compositeKey: String

    @Field(key: "discord_user_id")
    var discordUserId: String

    @Field(key: "guild_id")
    var guildId: String

    @Field(key: "facts")
    var facts: [String]

    @Field(key: "reputation")
    var reputation: Double

    @Field(key: "interaction_count")
    var interactionCount: Int

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
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
