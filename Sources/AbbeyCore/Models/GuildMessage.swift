import Foundation
import SwiftData

/// Mirrors `GuildMessage` from the Vapor/Fluent bot (see bot-architecture.md).
/// This is a local persisted message log, not a live cache of Discord's message store.
@Model
public final class GuildMessage {
    @Attribute(.unique) public var discordMessageId: String
    public var channelId: String
    public var guildId: String
    public var authorId: String
    public var content: String
    public var createdAt: Date

    public init(discordMessageId: String, channelId: String, guildId: String, authorId: String, content: String, createdAt: Date = .now) {
        self.discordMessageId = discordMessageId
        self.channelId = channelId
        self.guildId = guildId
        self.authorId = authorId
        self.content = content
        self.createdAt = createdAt
    }
}
