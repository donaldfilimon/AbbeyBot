import Foundation
import SwiftData

/// Pulls AbbeyServer list endpoints into local SwiftData (sync pull MVP).
///
/// Upsert rules:
/// - `UserMemory` by `compositeKey` — facts, reputation, interactionCount, updatedAt (**server wins**)
/// - `ChannelContext` by `compositeKey` — summary, messageCount, updatedAt (**server wins**)
/// - `GuildMessage` by `discordMessageId` — insert if missing; do not clobber existing
/// - `ReputationEvent` / `InteractionLog` — insert-if-missing by Fluent `serverId` only
///   (rows without `id` are skipped — no fragile composite identity)
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
        async let usersTask = client.fetchUsers(limit: limit)
        async let channelsTask = client.fetchChannels(limit: limit)
        async let messagesTask = client.fetchMessages(limit: limit)
        async let reputationTask = client.fetchReputation(limit: limit)
        async let interactionsTask = client.fetchInteractions(limit: limit)
        async let equityTask = client.fetchEquity(limit: limit)

        let users = try await usersTask
        let channels = try await channelsTask
        let messages = try await messagesTask
        let reputation = try await reputationTask
        let interactions = try await interactionsTask
        let equity = try await equityTask

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

    private static func firstMatching<T: PersistentModel>(
        _ type: T.Type,
        predicate: Predicate<T>,
        in context: ModelContext
    ) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @discardableResult
    private static func upsertUsers(_ rows: [SyncDTO.User], into context: ModelContext) throws -> Int {
        var count = 0
        for row in rows {
            let key = row.compositeKey
            if let existing = try firstMatching(UserMemory.self, predicate: #Predicate { $0.compositeKey == key }, in: context) {
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
    private static func upsertChannels(_ rows: [SyncDTO.Channel], into context: ModelContext) throws -> Int {
        var count = 0
        for row in rows {
            let key = row.compositeKey
            if let existing = try firstMatching(ChannelContext.self, predicate: #Predicate { $0.compositeKey == key }, in: context) {
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
    private static func insertMissingMessages(_ rows: [SyncDTO.Message], into context: ModelContext) throws -> Int {
        var inserted = 0
        for row in rows {
            let messageId = row.discordMessageId
            if try firstMatching(GuildMessage.self, predicate: #Predicate { $0.discordMessageId == messageId }, in: context) != nil {
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
        _ rows: [SyncDTO.Reputation],
        into context: ModelContext
    ) throws -> Int {
        var inserted = 0
        for row in rows {
            guard let serverId = row.id else { continue }
            if try firstMatching(ReputationEvent.self, predicate: #Predicate { $0.serverId == serverId }, in: context) != nil {
                continue
            }
            context.insert(
                ReputationEvent(
                    serverId: serverId,
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
        _ rows: [SyncDTO.Interaction],
        into context: ModelContext
    ) throws -> Int {
        var inserted = 0
        for row in rows {
            guard let serverId = row.id else { continue }
            if try firstMatching(InteractionLog.self, predicate: #Predicate { $0.serverId == serverId }, in: context) != nil {
                continue
            }
            context.insert(
                InteractionLog(
                    serverId: serverId,
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
        _ rows: [SyncDTO.Equity],
        into context: ModelContext
    ) throws -> Int {
        var count = 0
        for row in rows {
            let symbol = row.symbol
            if let existing = try firstMatching(EquityIdea.self, predicate: #Predicate { $0.symbol == symbol }, in: context) {
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
