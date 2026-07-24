import Foundation
import SwiftData

/// Pulls AbbeyServer list endpoints into local SwiftData (sync pull MVP).
///
/// Upsert rules:
/// - `UserMemory` by `compositeKey` — facts, reputation, interactionCount, updatedAt (**server wins**)
/// - `ChannelContext` by `compositeKey` — summary, messageCount, updatedAt (**server wins**)
/// - `GuildMessage` by `discordMessageId` — insert if missing; do not clobber existing
/// - `ReputationEvent` — insert-if-missing by Fluent `serverId`; else skip dupes by
///   (userId, guildId, reason, createdAt) best-effort
/// - `InteractionLog` — insert-if-missing by Fluent `serverId`; else by
///   (commandName, userId, createdAt, latencyMs)
/// - `EquityIdea` by `symbol` — thesis/score/factors/generatedAt (**server wins**) or insert
enum SyncPull {
    static let defaultLimit = 500

    struct Counts: Sendable {
        var usersUpserted: Int
        var channelsUpserted: Int
        var messagesInserted: Int
        var reputationInserted: Int
        var interactionsInserted: Int
        var equityUpserted: Int
    }

    /// Fetch list endpoints (`limit` clamped to 500) and upsert into `container`.
    /// Throws on network/decode/store failures; local store is only mutated after a successful fetch set.
    @MainActor
    static func run(
        into container: ModelContainer,
        client: AbbeyServerClient = .shared,
        limit: Int = defaultLimit
    ) async throws -> Counts {
        let users = try await client.fetchUsers(limit: limit)
        let channels = try await client.fetchChannels(limit: limit)
        let messages = try await client.fetchMessages(limit: limit)
        let reputation = try await client.fetchReputation(limit: limit)
        let interactions = try await client.fetchInteractions(limit: limit)
        let equity = try await client.fetchEquity(limit: limit)

        let context = ModelContext(container)
        let usersUpserted = try upsertUsers(users, into: context)
        let channelsUpserted = try upsertChannels(channels, into: context)
        let messagesInserted = try insertMissingMessages(messages, into: context)
        let reputationInserted = try insertMissingReputation(reputation, into: context)
        let interactionsInserted = try insertMissingInteractions(interactions, into: context)
        let equityUpserted = try upsertEquity(equity, into: context)
        try context.save()

        return Counts(
            usersUpserted: usersUpserted,
            channelsUpserted: channelsUpserted,
            messagesInserted: messagesInserted,
            reputationInserted: reputationInserted,
            interactionsInserted: interactionsInserted,
            equityUpserted: equityUpserted
        )
    }

    // MARK: - Upserts

    @discardableResult
    private static func upsertUsers(_ rows: [AbbeyServerClient.SyncUserDTO], into context: ModelContext) throws -> Int {
        var count = 0
        for row in rows {
            let key = row.compositeKey
            let descriptor = FetchDescriptor<UserMemory>(predicate: #Predicate { $0.compositeKey == key })
            if let existing = try context.fetch(descriptor).first {
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
    private static func upsertChannels(_ rows: [AbbeyServerClient.SyncChannelDTO], into context: ModelContext) throws -> Int {
        var count = 0
        for row in rows {
            let key = row.compositeKey
            let descriptor = FetchDescriptor<ChannelContext>(predicate: #Predicate { $0.compositeKey == key })
            if let existing = try context.fetch(descriptor).first {
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
    private static func insertMissingMessages(_ rows: [AbbeyServerClient.SyncMessageDTO], into context: ModelContext) throws -> Int {
        var inserted = 0
        for row in rows {
            let messageId = row.discordMessageId
            let descriptor = FetchDescriptor<GuildMessage>(predicate: #Predicate { $0.discordMessageId == messageId })
            if try context.fetch(descriptor).first != nil {
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

    @discardableResult
    private static func insertMissingReputation(
        _ rows: [AbbeyServerClient.SyncReputationDTO],
        into context: ModelContext
    ) throws -> Int {
        var inserted = 0
        for row in rows {
            if let serverId = row.id {
                let descriptor = FetchDescriptor<ReputationEvent>(predicate: #Predicate { $0.serverId == serverId })
                if try context.fetch(descriptor).first != nil {
                    continue
                }
            } else {
                let userId = row.userId
                let guildId = row.guildId
                let reason = row.reason
                let createdAt = row.createdAt ?? .now
                let descriptor = FetchDescriptor<ReputationEvent>(
                    predicate: #Predicate {
                        $0.userId == userId
                            && $0.guildId == guildId
                            && $0.reason == reason
                            && $0.createdAt == createdAt
                    }
                )
                if try context.fetch(descriptor).first != nil {
                    continue
                }
            }
            context.insert(
                ReputationEvent(
                    serverId: row.id,
                    userId: row.userId,
                    guildId: row.guildId,
                    delta: row.delta,
                    reason: row.reason,
                    createdAt: row.createdAt ?? .now
                )
            )
            inserted += 1
        }
        return inserted
    }

    @discardableResult
    private static func insertMissingInteractions(
        _ rows: [AbbeyServerClient.SyncInteractionDTO],
        into context: ModelContext
    ) throws -> Int {
        var inserted = 0
        for row in rows {
            if let serverId = row.id {
                let descriptor = FetchDescriptor<InteractionLog>(predicate: #Predicate { $0.serverId == serverId })
                if try context.fetch(descriptor).first != nil {
                    continue
                }
            } else {
                let commandName = row.commandName
                let userId = row.userId
                let createdAt = row.createdAt ?? .now
                let latencyMs = row.latencyMs
                let descriptor = FetchDescriptor<InteractionLog>(
                    predicate: #Predicate {
                        $0.commandName == commandName
                            && $0.userId == userId
                            && $0.createdAt == createdAt
                            && $0.latencyMs == latencyMs
                    }
                )
                if try context.fetch(descriptor).first != nil {
                    continue
                }
            }
            context.insert(
                InteractionLog(
                    serverId: row.id,
                    commandName: row.commandName,
                    userId: row.userId,
                    guildId: row.guildId,
                    succeeded: row.succeeded,
                    latencyMs: row.latencyMs,
                    createdAt: row.createdAt ?? .now
                )
            )
            inserted += 1
        }
        return inserted
    }

    @discardableResult
    private static func upsertEquity(
        _ rows: [AbbeyServerClient.SyncEquityDTO],
        into context: ModelContext
    ) throws -> Int {
        var count = 0
        for row in rows {
            let symbol = row.symbol
            let descriptor = FetchDescriptor<EquityIdea>(predicate: #Predicate { $0.symbol == symbol })
            if let existing = try context.fetch(descriptor).first {
                existing.thesisSummary = row.thesisSummary
                existing.syntheticScore = row.syntheticScore
                existing.factorBreakdown = row.factorBreakdown
                existing.generatedAt = row.generatedAt ?? existing.generatedAt
            } else {
                context.insert(
                    EquityIdea(
                        symbol: row.symbol,
                        thesisSummary: row.thesisSummary,
                        syntheticScore: row.syntheticScore,
                        factorBreakdown: row.factorBreakdown,
                        generatedAt: row.generatedAt ?? .now
                    )
                )
            }
            count += 1
        }
        return count
    }
}
