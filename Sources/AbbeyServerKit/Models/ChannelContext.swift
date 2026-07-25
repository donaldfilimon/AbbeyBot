import Fluent
import Foundation
import Vapor

public final class ChannelContext: Model, Content, @unchecked Sendable {
    public static let schema = "channel_contexts"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "composite_key")
    public var compositeKey: String

    @Field(key: "channel_id")
    public var channelId: String

    @Field(key: "guild_id")
    public var guildId: String

    @Field(key: "summary")
    public var summary: String

    @Field(key: "message_count")
    public var messageCount: Int

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    /// Soft-delete tombstone for desktop↔server sync. Nil means live; non-nil means the
    /// row should be removed on pull (and excluded from full-list endpoints). Cleared if
    /// a later channel bump resurrects the row.
    @OptionalField(key: "deleted_at")
    public var deletedAt: Date?

    public init() {}

    public init(
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
