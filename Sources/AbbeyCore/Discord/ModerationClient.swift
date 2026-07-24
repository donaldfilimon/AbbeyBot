import Foundation
import DiscordBM

/// Discord moderation REST calls, always intended to be gated by `ConfirmationGate` in the app layer.
public struct ModerationClient: Sendable {
    public init() {}

    public func kick(client: any DiscordClient, guildId: String, userId: String, reason: String) async throws {
        try await client.deleteGuildMember(
            guildId: GuildSnowflake(guildId),
            userId: UserSnowflake(userId),
            reason: reason
        ).guardSuccess()
    }

    public func ban(client: any DiscordClient, guildId: String, userId: String, reason: String, deleteMessageSeconds: Int = 0) async throws {
        try await client.banUserFromGuild(
            guildId: GuildSnowflake(guildId),
            userId: UserSnowflake(userId),
            reason: reason,
            payload: .init(delete_message_seconds: deleteMessageSeconds)
        ).guardSuccess()
    }

    public func purge(client: any DiscordClient, channelId: String, messageIds: [String]) async throws {
        guard !messageIds.isEmpty else { return }
        if messageIds.count == 1, let only = messageIds.first {
            try await client.deleteMessage(
                channelId: ChannelSnowflake(channelId),
                messageId: MessageSnowflake(only)
            ).guardSuccess()
            return
        }
        try await client.bulkDeleteMessages(
            channelId: ChannelSnowflake(channelId),
            payload: .init(messages: messageIds.map { MessageSnowflake($0) })
        ).guardSuccess()
    }
}
