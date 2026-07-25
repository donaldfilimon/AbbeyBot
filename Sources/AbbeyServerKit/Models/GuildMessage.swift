import Fluent
import Foundation
import Vapor

public final class GuildMessage: Model, Content, @unchecked Sendable {
    public static let schema = "guild_messages"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "discord_message_id")
    public var discordMessageId: String

    @Field(key: "channel_id")
    public var channelId: String

    @Field(key: "guild_id")
    public var guildId: String

    @Field(key: "author_id")
    public var authorId: String

    @Field(key: "content")
    public var content: String

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @OptionalField(key: "deleted_at")
    public var deletedAt: Date?

    public init() {}

    public init(
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
