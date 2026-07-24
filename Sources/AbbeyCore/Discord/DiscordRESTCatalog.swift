import Foundation
import DiscordBM

/// Thin typed facade over DiscordBM REST endpoints used by the desktop app and handlers.
public struct DiscordRESTCatalog: Sendable {
    public let client: any DiscordClient

    public init(client: any DiscordClient) {
        self.client = client
    }

    public func sendMessage(channelId: String, content: String) async throws -> DiscordChannel.Message {
        try await client.createMessage(
            channelId: ChannelSnowflake(channelId),
            payload: .init(content: content)
        ).decode()
    }

    public func addReaction(channelId: String, messageId: String, emoji: String) async throws {
        try await client.addMessageReaction(
            channelId: ChannelSnowflake(channelId),
            messageId: MessageSnowflake(messageId),
            emoji: .unicodeEmoji(emoji)
        ).guardSuccess()
    }

    public func getChannel(id: String) async throws -> DiscordChannel {
        try await client.getChannel(id: ChannelSnowflake(id)).decode()
    }

    public func createGuildChannel(guildId: String, name: String, type: DiscordChannel.Kind = .guildText) async throws -> DiscordChannel {
        try await client.createGuildChannel(
            guildId: GuildSnowflake(guildId),
            payload: .init(name: name, type: type)
        ).decode()
    }

    public func createThreadFromMessage(channelId: String, messageId: String, name: String) async throws -> DiscordChannel {
        try await client.createThreadFromMessage(
            channelId: ChannelSnowflake(channelId),
            messageId: MessageSnowflake(messageId),
            payload: .init(name: name)
        ).decode()
    }

    public func listGuildMembers(guildId: String, limit: Int = 100) async throws -> [Guild.Member] {
        try await client.listGuildMembers(
            guildId: GuildSnowflake(guildId),
            limit: limit
        ).decode()
    }

    public func getGuildMember(guildId: String, userId: String) async throws -> Guild.Member {
        try await client.getGuildMember(
            guildId: GuildSnowflake(guildId),
            userId: UserSnowflake(userId)
        ).decode()
    }

    public func addGuildMemberRole(guildId: String, userId: String, roleId: String) async throws {
        try await client.addGuildMemberRole(
            guildId: GuildSnowflake(guildId),
            userId: UserSnowflake(userId),
            roleId: RoleSnowflake(roleId)
        ).guardSuccess()
    }

    public func createWebhook(channelId: String, name: String) async throws -> Webhook {
        try await client.createWebhook(
            channelId: ChannelSnowflake(channelId),
            payload: .init(name: name)
        ).decode()
    }

    public func executeWebhook(id: String, token: String, content: String) async throws {
        let address = WebhookAddress.deconstructed(id: WebhookSnowflake(id), token: token)
        try await client.executeWebhook(
            address: address,
            payload: .init(content: content)
        ).guardSuccess()
    }
}
