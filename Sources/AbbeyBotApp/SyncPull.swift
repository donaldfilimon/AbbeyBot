import AbbeyCore
import Foundation
import SwiftData

/// Pulls AbbeyServer list endpoints into local SwiftData (sync pull MVP).
///
/// Upsert rules:
/// - `UserMemory` by `compositeKey` — facts, reputation, interactionCount, updatedAt
///   (**last-write-wins by `updatedAt`**: an unsynced local edit newer than the remote row
///   survives a pull instead of being clobbered; caveat — this compares each side's own wall
///   clock, so it's not resilient to significant clock skew between desktop and server).
///   When the remote row carries a non-nil `deletedAt` at least as new as the local
///   `updatedAt`, the local SwiftData row is **hard-deleted** (tombstone application).
/// - `ChannelContext` by `compositeKey` — summary, messageCount, updatedAt (same last-write-wins
///   and tombstone rules)
/// - `GuildMessage` by `discordMessageId` — insert if missing; do not clobber existing;
///   remote `deletedAt` hard-deletes the local row
/// - `ReputationEvent` / `InteractionLog` — insert-if-missing by Fluent `serverId` only
///   (rows without `id` are skipped — no fragile composite identity); remote `deletedAt` hard-deletes
/// - `EquityIdea` by `symbol` — thesis/score/factors (**last-write-wins by `generatedAt`**:
///   ideas are regenerated rather than edited, so the more recently generated idea wins) or insert;
///   remote `deletedAt` hard-deletes when `deletedAt` ≥ local `generatedAt`
enum SyncPull {
    static let defaultLimit = 500

    struct Counts: Sendable {
        var usersUpserted: Int
        var channelsUpserted: Int
        var messagesInserted: Int
        var reputationInserted: Int
        var interactionsInserted: Int
        var equityUpserted: Int
        /// Independently safe compound boundaries for the next pull.
        var nextCursors: SyncPullCursorSet

        /// Compatibility view for session status and older tests.
        var nextCursor: Date? { nextCursors.earliestChangedAt }
    }

    /// Fetch list endpoints (`limit` clamped to 500) and upsert into `container`.
    /// Throws on network/decode/store failures; local store is only mutated after a successful fetch set.
    ///
    /// Pass `since` to fetch only rows the server has touched after that instant (`?since=`
    /// cursor). Callers supply the last *successful* cursor from `SyncCursorStore`, so a failed
    /// pull never advances past rows that were never applied. Incremental server pages are oldest
    /// change first: a short page advances through pull start, while a full page advances only
    /// through its newest returned change. Two caveats worth knowing:
    /// - The pull start remains the upper bound (never completion time) and persists across launches;
    ///   a missing/non-numeric store value degrades to a full pull.
    /// - The server compares against its own `updatedAt` clock, so a desktop clock running ahead
    ///   of the server can skip rows (same clock-skew family as the last-write-wins caveat above).
    @MainActor
    static func run(
        into container: ModelContainer,
        client: AbbeyServerClient = .shared,
        limit: Int = defaultLimit,
        cursors: SyncPullCursorSet = SyncPullCursorSet(),
        attemptStartedAt: Date = .now
    ) async throws -> Counts {
        let effectiveLimit = min(max(limit, 1), defaultLimit)
        let usersCursor = cursors.users ?? .initial
        let channelsCursor = cursors.channels ?? .initial
        let messagesCursor = cursors.messages ?? .initial
        let reputationCursor = cursors.reputation ?? .initial
        let interactionsCursor = cursors.interactions ?? .initial
        let equityCursor = cursors.equity ?? .initial

        async let usersTask = SyncPageDrain.run(
            initialCursor: usersCursor, attemptStartedAt: attemptStartedAt, limit: effectiveLimit
        ) { try await client.fetchUsersPage(limit: effectiveLimit, cursor: $0) }
        async let channelsTask = SyncPageDrain.run(
            initialCursor: channelsCursor, attemptStartedAt: attemptStartedAt, limit: effectiveLimit
        ) { try await client.fetchChannelsPage(limit: effectiveLimit, cursor: $0) }
        async let messagesTask = SyncPageDrain.run(
            initialCursor: messagesCursor, attemptStartedAt: attemptStartedAt, limit: effectiveLimit
        ) { try await client.fetchMessagesPage(limit: effectiveLimit, cursor: $0) }
        async let reputationTask = SyncPageDrain.run(
            initialCursor: reputationCursor, attemptStartedAt: attemptStartedAt, limit: effectiveLimit
        ) { try await client.fetchReputationPage(limit: effectiveLimit, cursor: $0) }
        async let interactionsTask = SyncPageDrain.run(
            initialCursor: interactionsCursor, attemptStartedAt: attemptStartedAt, limit: effectiveLimit
        ) { try await client.fetchInteractionsPage(limit: effectiveLimit, cursor: $0) }
        async let equityTask = SyncPageDrain.run(
            initialCursor: equityCursor, attemptStartedAt: attemptStartedAt, limit: effectiveLimit
        ) { try await client.fetchEquityPage(limit: effectiveLimit, cursor: $0) }

        let usersDrain = try await usersTask
        let channelsDrain = try await channelsTask
        let messagesDrain = try await messagesTask
        let reputationDrain = try await reputationTask
        let interactionsDrain = try await interactionsTask
        let equityDrain = try await equityTask

        let users = usersDrain.rows
        let channels = channelsDrain.rows
        let messages = messagesDrain.rows
        let reputation = reputationDrain.rows
        let interactions = interactionsDrain.rows
        let equity = equityDrain.rows

        let context = ModelContext(container)
        let usersUpserted = try upsertUsers(users, into: context)
        let channelsUpserted = try upsertChannels(channels, into: context)
        let messagesInserted = try insertMissingMessages(messages, into: context)
        let reputationInserted = try insertMissingReputation(reputation, into: context)
        let interactionsInserted = try insertMissingInteractions(interactions, into: context)
        let equityUpserted = try upsertEquity(equity, into: context)
        try context.save()

        var nextCursors = cursors
        nextCursors.users = usersDrain.nextCursor
        nextCursors.channels = channelsDrain.nextCursor
        nextCursors.messages = messagesDrain.nextCursor
        nextCursors.reputation = reputationDrain.nextCursor
        nextCursors.interactions = interactionsDrain.nextCursor
        nextCursors.equity = equityDrain.nextCursor

        return Counts(
            usersUpserted: usersUpserted,
            channelsUpserted: channelsUpserted,
            messagesInserted: messagesInserted,
            reputationInserted: reputationInserted,
            interactionsInserted: interactionsInserted,
            equityUpserted: equityUpserted,
            nextCursors: nextCursors
        )
    }

    /// Source-compatible entry point for callers still holding the legacy shared timestamp.
    @MainActor
    static func run(
        into container: ModelContainer,
        client: AbbeyServerClient = .shared,
        limit: Int = defaultLimit,
        since: Date?,
        attemptStartedAt: Date = .now
    ) async throws -> Counts {
        try await run(
            into: container,
            client: client,
            limit: limit,
            cursors: since.map { SyncPullCursorSet(legacyTimestamp: $0) } ?? SyncPullCursorSet(),
            attemptStartedAt: attemptStartedAt
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
    static func upsertUsers(_ rows: [SyncDTO.User], into context: ModelContext) throws -> Int {
        var count = 0
        for row in rows {
            let key = row.compositeKey
            let existing = try firstMatching(UserMemory.self, predicate: #Predicate { $0.compositeKey == key }, in: context)

            if let deletedAt = row.deletedAt {
                // Tombstone: remove local row when the remote delete is at least as new as local.
                if let existing {
                    let remoteStamp = row.updatedAt ?? deletedAt
                    if remoteStamp >= existing.updatedAt {
                        context.delete(existing)
                    }
                }
                // Never insert a tombstone as a live local row.
                count += 1
                continue
            }

            if let existing {
                // Last-write-wins: only apply the remote row if it's at least as new as the
                // local one, so an unsynced local edit made since the last pull survives.
                if let remoteUpdatedAt = row.updatedAt, remoteUpdatedAt < existing.updatedAt {
                    count += 1
                    continue
                }
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
    static func upsertChannels(_ rows: [SyncDTO.Channel], into context: ModelContext) throws -> Int {
        var count = 0
        for row in rows {
            let key = row.compositeKey
            let existing = try firstMatching(ChannelContext.self, predicate: #Predicate { $0.compositeKey == key }, in: context)

            if let deletedAt = row.deletedAt {
                if let existing {
                    let remoteStamp = row.updatedAt ?? deletedAt
                    if remoteStamp >= existing.updatedAt {
                        context.delete(existing)
                    }
                }
                count += 1
                continue
            }

            if let existing {
                // Last-write-wins: only apply the remote row if it's at least as new as the
                // local one, so an unsynced local edit made since the last pull survives.
                if let remoteUpdatedAt = row.updatedAt, remoteUpdatedAt < existing.updatedAt {
                    count += 1
                    continue
                }
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
    static func insertMissingMessages(_ rows: [SyncDTO.Message], into context: ModelContext) throws -> Int {
        var inserted = 0
        for row in rows {
            let messageId = row.discordMessageId
            let existing = try firstMatching(GuildMessage.self, predicate: #Predicate { $0.discordMessageId == messageId }, in: context)
            if row.deletedAt != nil {
                if let existing { context.delete(existing) }
                continue
            }
            if existing != nil { continue }
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
            let existing = try firstMatching(ReputationEvent.self, predicate: #Predicate { $0.serverId == serverId }, in: context)
            if row.deletedAt != nil {
                if let existing { context.delete(existing) }
                continue
            }
            if existing != nil { continue }
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
            let existing = try firstMatching(InteractionLog.self, predicate: #Predicate { $0.serverId == serverId }, in: context)
            if row.deletedAt != nil {
                if let existing { context.delete(existing) }
                continue
            }
            if existing != nil { continue }
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
    static func upsertEquity(
        _ rows: [SyncDTO.Equity],
        into context: ModelContext
    ) throws -> Int {
        var count = 0
        for row in rows {
            let symbol = row.symbol
            let existing = try firstMatching(EquityIdea.self, predicate: #Predicate { $0.symbol == symbol }, in: context)

            if let deletedAt = row.deletedAt {
                // Tombstone stamp is `deletedAt` (soft-delete does not bump `generatedAt`).
                if let existing, deletedAt >= existing.generatedAt {
                    context.delete(existing)
                }
                count += 1
                continue
            }

            if let existing {
                // Last-write-wins by generation time: equity ideas are regenerated rather than
                // edited, so the more recently generated idea for a symbol wins. Keeps a locally
                // generated idea from being clobbered by a staler one the server still holds.
                if let remoteGeneratedAt = row.generatedAt, remoteGeneratedAt < existing.generatedAt {
                    count += 1
                    continue
                }
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
