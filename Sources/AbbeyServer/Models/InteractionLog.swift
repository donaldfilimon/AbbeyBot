import Fluent
import Foundation
import Vapor

final class InteractionLog: Model, Content, @unchecked Sendable {
    static let schema = "interaction_logs"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "command_name")
    var commandName: String

    @Field(key: "user_id")
    var userId: String

    @Field(key: "guild_id")
    var guildId: String

    @Field(key: "succeeded")
    var succeeded: Bool

    @Field(key: "latency_ms")
    var latencyMs: Double

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
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
