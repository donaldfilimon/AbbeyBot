import Fluent
import Foundation
import Vapor

final class ReputationEvent: Model, Content, @unchecked Sendable {
    static let schema = "reputation_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: String

    @Field(key: "guild_id")
    var guildId: String

    @Field(key: "delta")
    var delta: Double

    @Field(key: "reason")
    var reason: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: String,
        guildId: String,
        delta: Double,
        reason: String
    ) {
        self.id = id
        self.userId = userId
        self.guildId = guildId
        self.delta = delta
        self.reason = reason
    }
}
