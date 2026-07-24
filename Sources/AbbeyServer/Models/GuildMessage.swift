import Fluent
import Foundation
import Vapor

final class GuildMessage: Model, Content, @unchecked Sendable {
    static let schema = "guild_messages"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "discord_message_id")
    var discordMessageId: String

    @Field(key: "channel_id")
    var channelId: String

    @Field(key: "guild_id")
    var guildId: String

    @Field(key: "author_id")
    var authorId: String

    @Field(key: "content")
    var content: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        discordMessageId: String,
        channelId: String,
        guildId: String,
        authorId: String,
        content: String,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.discordMessageId = discordMessageId
        self.channelId = channelId
        self.guildId = guildId
        self.authorId = authorId
        self.content = content
        self.createdAt = createdAt
    }
}
