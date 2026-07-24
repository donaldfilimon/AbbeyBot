import Fluent
import Foundation
import Vapor

final class ChannelContext: Model, Content, @unchecked Sendable {
    static let schema = "channel_contexts"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "composite_key")
    var compositeKey: String

    @Field(key: "channel_id")
    var channelId: String

    @Field(key: "guild_id")
    var guildId: String

    @Field(key: "summary")
    var summary: String

    @Field(key: "message_count")
    var messageCount: Int

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        channelId: String,
        guildId: String,
        summary: String = "",
        messageCount: Int = 0
    ) {
        self.id = id
        self.compositeKey = "\(guildId):\(channelId)"
        self.channelId = channelId
        self.guildId = guildId
        self.summary = summary
        self.messageCount = messageCount
    }
}
