import Foundation
import DiscordBM

/// Durable-ingest outcome carried with one inbound message.
///
/// A duplicate or failed write must not produce a reply: doing so would reuse ambient
/// strategy state and would acknowledge work that was never persisted.  The strategy is
/// therefore attached only to the message whose ingest selected it.
public enum MessageIngestOutcome: Sendable, Equatable {
    case inserted(strategy: StrategyAction)
    case duplicate
    case failed

    public var strategy: StrategyAction? {
        guard case .inserted(let strategy) = self else { return nil }
        return strategy
    }

    public var wasInserted: Bool { strategy != nil }
}

/// Turns Discord MESSAGE_CREATE into local ingest + optional persona reply.
public struct MessageIngress: Sendable {
    public typealias IngestHandler = @Sendable (
        _ content: String,
        _ channelId: String,
        _ guildId: String,
        _ authorId: String,
        _ messageId: String
    ) async -> MessageIngestOutcome

    public typealias ReplyHandler = @Sendable (
        _ content: String,
        _ channelId: String,
        _ guildId: String,
        _ authorId: String,
        _ strategy: StrategyAction
    ) async -> String?

    public typealias CooldownCheck = @Sendable (_ userId: String, _ guildId: String) async -> Bool
    public typealias MarkReplied = @Sendable (_ userId: String, _ guildId: String) async -> Void
    public typealias NoteReply = @Sendable (_ sourceMessageId: String, _ replyMessageId: String) async -> Void

    private let ingest: IngestHandler
    private let craftReply: ReplyHandler
    private let isCoolingDown: CooldownCheck
    private let markReplied: MarkReplied
    private let noteReply: NoteReply
    private let botUserId: @Sendable () async -> String?

    public init(
        ingest: @escaping IngestHandler,
        craftReply: @escaping ReplyHandler,
        isCoolingDown: @escaping CooldownCheck,
        markReplied: @escaping MarkReplied,
        noteReply: @escaping NoteReply = { _, _ in },
        botUserId: @escaping @Sendable () async -> String?
    ) {
        self.ingest = ingest
        self.craftReply = craftReply
        self.isCoolingDown = isCoolingDown
        self.markReplied = markReplied
        self.noteReply = noteReply
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

        let outcome = await ingest(content, channelId, guildId, authorId, messageId)
        guard case .inserted(let strategy) = outcome else { return }

        if await isCoolingDown(authorId, guildId) { return }
        guard let reply = await craftReply(content, channelId, guildId, authorId, strategy), !reply.isEmpty else { return }

        do {
            let response = try await client.createMessage(
                channelId: message.channel_id,
                payload: .init(
                    content: reply,
                    message_reference: .init(message_id: message.id)
                )
            )
            try response.guardSuccess()
            await markReplied(authorId, guildId)
            // The reply was delivered either way; a body that fails to decode only costs
            // the delayed-reward link for this one message.
            if let sent = try? response.decode() {
                await noteReply(messageId, sent.id.rawValue)
            }
        } catch {
            // Surface via client errors; ingest already succeeded.
        }
    }
}
