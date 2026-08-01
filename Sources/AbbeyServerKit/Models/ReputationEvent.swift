import Fluent
import Foundation
import Vapor

public final class ReputationEvent: Model, Content, @unchecked Sendable {
    public static let schema = "reputation_events"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "user_id")
    public var userId: String

    @Field(key: "guild_id")
    public var guildId: String

    @Field(key: "delta")
    public var delta: Double

    @Field(key: "reason")
    public var reason: String

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    /// Original server creation clock for a CLI-mirrored row.
    @OptionalField(key: "source_created_at")
    public var sourceCreatedAt: Date?

    @OptionalField(key: "deleted_at")
    public var deletedAt: Date?

    public init() {}

    public init(
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
