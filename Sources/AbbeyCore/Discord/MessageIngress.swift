import Foundation
import DiscordBM
import SwiftData

/// Turns Discord MESSAGE_CREATE into local ingest + optional persona reply.
public struct MessageIngress: Sendable {
    public typealias IngestHandler = @Sendable (
        _ content: String,
        _ channelId: String,
        _ guildId: String,
        _ authorId: String,
        _ messageId: String
    ) async -> Void

    public typealias ReplyHandler = @Sendable (
        _ content: String,
        _ channelId: String,
        _ guildId: String,
        _ authorId: String
    ) async -> String?

    public typealias CooldownCheck = @Sendable (_ userId: String, _ guildId: String) async -> Bool
    public typealias MarkReplied = @Sendable (_ userId: String, _ guildId: String) async -> Void

    private let ingest: IngestHandler
    private let craftReply: ReplyHandler
    private let isCoolingDown: CooldownCheck
    private let markReplied: MarkReplied
    private let botUserId: @Sendable () async -> String?

    public init(
        ingest: @escaping IngestHandler,
        craftReply: @escaping ReplyHandler,
        isCoolingDown: @escaping CooldownCheck,
        markReplied: @escaping MarkReplied,
        botUserId: @escaping @Sendable () async -> String?
    ) {
        self.ingest = ingest
        self.craftReply = craftReply
        self.isCoolingDown = isCoolingDown
        self.markReplied = markReplied
        self.botUserId = botUserId
    }

    public func handle(_ message: Gateway.MessageCreate, client: any DiscordClient) async {
        guard message.author?.bot != true else { return }
        let content = message.content
        guard !content.isEmpty else { return }
        if let botId = await botUserId(), message.author?.id.rawValue == botId { return }

        let channelId = message.channel_id.rawValue
        let guildId = message.guild_id?.rawValue ?? "DM"
        let authorId = message.author?.id.rawValue ?? ""
        let messageId = message.id.rawValue

        await ingest(content, channelId, guildId, authorId, messageId)

        if await isCoolingDown(authorId, guildId) { return }
        guard let reply = await craftReply(content, channelId, guildId, authorId), !reply.isEmpty else { return }

        do {
            try await client.createMessage(
                channelId: message.channel_id,
                payload: .init(
                    content: reply,
                    message_reference: .init(message_id: message.id)
                )
            ).guardSuccess()
            await markReplied(authorId, guildId)
        } catch {
            // Surface via client errors; ingest already succeeded.
        }
    }
}
