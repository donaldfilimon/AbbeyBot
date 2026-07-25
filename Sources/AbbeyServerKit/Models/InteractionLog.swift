import Fluent
import Foundation
import Vapor

public final class InteractionLog: Model, Content, @unchecked Sendable {
    public static let schema = "interaction_logs"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "command_name")
    public var commandName: String

    @Field(key: "user_id")
    public var userId: String

    @Field(key: "guild_id")
    public var guildId: String

    @Field(key: "succeeded")
    public var succeeded: Bool

    @Field(key: "latency_ms")
    public var latencyMs: Double

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @OptionalField(key: "deleted_at")
    public var deletedAt: Date?

    public init() {}

    public init(
        id: UUID? = nil,
        commandName: String,
        userId: String,
        guildId: String,
        succeeded: Bool,
        latencyMs: Double
    ) {
        self.id = id
        self.commandName = commandName
        self.userId = userId
        self.guildId = guildId
        self.succeeded = succeeded
        self.latencyMs = latencyMs
    }
}
