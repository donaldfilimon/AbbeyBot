import Foundation
import SwiftData

/// Pulls AbbeyServer list endpoints into local SwiftData (sync pull MVP).
///
/// Upsert rules:
/// - `UserMemory` by `compositeKey` — facts, reputation, interactionCount, updatedAt (**server wins**)
/// - `ChannelContext` by `compositeKey` — summary, messageCount, updatedAt (**server wins**)
/// - `GuildMessage` by `discordMessageId` — insert if missing; do not clobber existing
enum SyncPull {
    static let defaultLimit = 500

    struct Counts: Sendable {
        var usersUpserted: Int
        var channelsUpserted: Int
        var messagesInserted: Int
    }

    /// Fetch users/channels/messages (`limit` clamped to 500) and upsert into `container`.
    /// Throws on network/decode failures; local store is only mutated after a successful fetch set.
    @MainActor
    static func run(
        into container: ModelContainer,
        client: AbbeyServerClient = .shared,
        limit: Int = defaultLimit
    ) async throws -> Counts {
        let users = try await client.fetchUsers(limit: limit)
        let channels = try await client.fetchChannels(limit: limit)
        let messages = try await client.fetchMessages(limit: limit)

        let context = ModelContext(container)
        let usersUpserted = upsertUsers(users, into: context)
        let channelsUpserted = upsertChannels(channels, into: context)
        let messagesInserted = insertMissingMessages(messages, into: context)
        try context.save()

        return Counts(
            usersUpserted: usersUpserted,
            channelsUpserted: channelsUpserted,
            messagesInserted: messagesInserted
        )
    }

    // MARK: - Upserts

    @discardableResult
    private static func upsertUsers(_ rows: [AbbeyServerClient.SyncUserDTO], into context: ModelContext) -> Int {
        var count = 0
        for row in rows {
            let key = row.compositeKey
            let descriptor = FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })
            if let existing = try? context.fetch(descriptor).first {
                existing.facts = row.facts
                existing.reputation = row.reputation
                existing.interactionCount = row.interactionCount
                existing.updatedAt = row.updatedAt ?? existing.updatedAt
            } else {
                let memory = UserMemory(
                    discordUserId: row.discordUserId,
                    guildId: row.guildId,
                    facts: row.facts,
                    reputation: row.reputation,
                    interactionCount: row.interactionCount,
                    updatedAt: row.updatedAt ?? .now
                )
                memory.compositeKey = key
                context.insert(memory)
            }
            count += 1
        }
        return count
    }

    @discardableResult
    private static func upsertChannels(_ rows: [AbbeyServerClient.SyncChannelDTO], into context: ModelContext) -> Int {
        var count = 0
        for row in rows {
            let key = row.compositeKey
            let descriptor = FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.compositeKey == key })
            if let existing = try? context.fetch(descriptor).first {
                existing.summary = row.summary
                existing.messageCount = row.messageCount
                existing.updatedAt = row.updatedAt ?? existing.updatedAt
            } else {
                let channel = ChannelContext(
                    channelId: row.channelId,
                    guildId: row.guildId,
                    summary: row.summary,
                    messageCount: row.messageCount,
                    updatedAt: row.updatedAt ?? .now
                )
                channel.compositeKey = key
                context.insert(channel)
            }
            count += 1
        }
        return count
    }

    @discardableResult
    private static func insertMissingMessages(_ rows: [AbbeyServerClient.SyncMessageDTO], into context: ModelContext) -> Int {
        var inserted = 0
        for row in rows {
            let messageId = row.discordMessageId
            let descriptor = FetchDescriptor<GuildMessage>(predicate: #Predicate { $0.discordMessageId == messageId })
            if (try? context.fetch(descriptor).first) != nil {
                continue
            }
            context.insert(
                GuildMessage(
                    discordMessageId: row.discordMessageId,
                    channelId: row.channelId,
                    guildId: row.guildId,
                    authorId: row.authorId,
                    content: row.content,
                    createdAt: row.createdAt ?? .now
                )
            )
            inserted += 1
        }
        return inserted
    }
}
