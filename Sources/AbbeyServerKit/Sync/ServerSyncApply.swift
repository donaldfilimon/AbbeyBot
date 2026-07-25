import Fluent
import Foundation

/// Applies pulled server rows into a *local* Fluent database (the CLI's SQLite). Mirrors the
/// desktop `SyncPull` conflict rules on the Fluent side:
///
/// - Users/channels by `compositeKey` — last-write-wins by `updatedAt`; a remote `deletedAt`
///   at least as new as the local `updatedAt` hard-deletes the local row; tombstones are
///   never inserted as live rows.
/// - Messages by `discordMessageId` — insert if missing; remote `deletedAt` hard-deletes.
/// - Reputation/interactions by Fluent `id` — insert if missing (rows without `id` skipped);
///   remote `deletedAt` hard-deletes.
/// - Equity by `symbol` — last-write-wins by `generatedAt`; a remote `deletedAt` ≥ local
///   `generatedAt` hard-deletes.
///
/// Caveat (same wall-clock caveat as the desktop): local `updatedAt`/`generatedAt` are Fluent
/// timestamps stamped at apply time, so LWW compares apply time, not the original server
/// stamps. Good enough for a single-writer CLI mirror; not a CRDT.
public enum ServerSyncApply {
    public struct Counts: Equatable, Sendable {
        public var usersApplied = 0
        public var channelsApplied = 0
        public var messagesApplied = 0
        public var reputationApplied = 0
        public var interactionsApplied = 0
        public var equityApplied = 0

        public init() {}

        public var summary: String {
            "\(usersApplied) users, \(channelsApplied) channels, \(messagesApplied) messages, "
                + "\(reputationApplied) reputation, \(interactionsApplied) interactions, \(equityApplied) equity"
        }
    }

    public static func apply(
        users: [ServerSyncDTO.User],
        channels: [ServerSyncDTO.Channel],
        messages: [ServerSyncDTO.Message],
        reputation: [ServerSyncDTO.Reputation],
        interactions: [ServerSyncDTO.Interaction],
        equity: [ServerSyncDTO.Equity],
        on db: any Database
    ) async throws -> Counts {
        var counts = Counts()
        counts.usersApplied = try await applyUsers(users, on: db)
        counts.channelsApplied = try await applyChannels(channels, on: db)
        counts.messagesApplied = try await applyMessages(messages, on: db)
        counts.reputationApplied = try await applyReputation(reputation, on: db)
        counts.interactionsApplied = try await applyInteractions(interactions, on: db)
        counts.equityApplied = try await applyEquity(equity, on: db)
        return counts
    }

    @discardableResult
    public static func applyUsers(_ rows: [ServerSyncDTO.User], on db: any Database) async throws -> Int {
        var applied = 0
        for row in rows {
            let existing = try await UserMemory.query(on: db)
                .filter(\.$compositeKey == row.compositeKey)
                .first()

            if let deletedAt = row.deletedAt {
                if let existing {
                    let remoteStamp = row.updatedAt ?? deletedAt
                    if remoteStamp >= (existing.updatedAt ?? .distantPast) {
                        try await existing.delete(on: db)
                    }
                }
                applied += 1
                continue
            }

            if let existing {
                if let remoteUpdatedAt = row.updatedAt,
                   let localUpdatedAt = existing.updatedAt,
                   remoteUpdatedAt < localUpdatedAt
                {
                    applied += 1
                    continue
                }
                existing.facts = row.facts
                existing.reputation = row.reputation
                existing.interactionCount = row.interactionCount
                try await existing.save(on: db)
            } else {
                try await UserMemory(
                    discordUserId: row.discordUserId,
                    guildId: row.guildId,
                    facts: row.facts,
                    reputation: row.reputation,
                    interactionCount: row.interactionCount
                ).create(on: db)
            }
            applied += 1
        }
        return applied
    }

    @discardableResult
    public static func applyChannels(_ rows: [ServerSyncDTO.Channel], on db: any Database) async throws -> Int {
        var applied = 0
        for row in rows {
            let existing = try await ChannelContext.query(on: db)
                .filter(\.$compositeKey == row.compositeKey)
                .first()

            if let deletedAt = row.deletedAt {
                if let existing {
                    let remoteStamp = row.updatedAt ?? deletedAt
                    if remoteStamp >= (existing.updatedAt ?? .distantPast) {
                        try await existing.delete(on: db)
                    }
                }
                applied += 1
                continue
            }

            if let existing {
                if let remoteUpdatedAt = row.updatedAt,
                   let localUpdatedAt = existing.updatedAt,
                   remoteUpdatedAt < localUpdatedAt
                {
                    applied += 1
                    continue
                }
                existing.summary = row.summary
                existing.messageCount = row.messageCount
                try await existing.save(on: db)
            } else {
                try await ChannelContext(
                    channelId: row.channelId,
                    guildId: row.guildId,
                    summary: row.summary,
                    messageCount: row.messageCount
                ).create(on: db)
            }
            applied += 1
        }
        return applied
    }

    @discardableResult
    public static func applyMessages(_ rows: [ServerSyncDTO.Message], on db: any Database) async throws -> Int {
        var applied = 0
        for row in rows {
            let existing = try await GuildMessage.query(on: db)
                .filter(\.$discordMessageId == row.discordMessageId)
                .first()

            if row.deletedAt != nil {
                if let existing {
                    try await existing.delete(on: db)
                }
                applied += 1
                continue
            }

            guard existing == nil else { continue }
            try await GuildMessage(
                discordMessageId: row.discordMessageId,
                channelId: row.channelId,
                guildId: row.guildId,
                authorId: row.authorId,
                content: row.content
            ).create(on: db)
            applied += 1
        }
        return applied
    }

    @discardableResult
    public static func applyReputation(_ rows: [ServerSyncDTO.Reputation], on db: any Database) async throws -> Int {
        var applied = 0
        for row in rows {
            guard let id = row.id else { continue }
            let existing = try await ReputationEvent.query(on: db).filter(\.$id == id).first()

            if row.deletedAt != nil {
                if let existing {
                    try await existing.delete(on: db)
                }
                applied += 1
                continue
            }

            guard existing == nil else { continue }
            try await ReputationEvent(
                id: id,
                userId: row.userId,
                guildId: row.guildId,
                delta: row.delta,
                reason: row.reason
            ).create(on: db)
            applied += 1
        }
        return applied
    }

    @discardableResult
    public static func applyInteractions(_ rows: [ServerSyncDTO.Interaction], on db: any Database) async throws -> Int {
        var applied = 0
        for row in rows {
            guard let id = row.id else { continue }
            let existing = try await InteractionLog.query(on: db).filter(\.$id == id).first()

            if row.deletedAt != nil {
                if let existing {
                    try await existing.delete(on: db)
                }
                applied += 1
                continue
            }

            guard existing == nil else { continue }
            try await InteractionLog(
                id: id,
                commandName: row.commandName,
                userId: row.userId,
                guildId: row.guildId,
                succeeded: row.succeeded,
                latencyMs: row.latencyMs
            ).create(on: db)
            applied += 1
        }
        return applied
    }

    @discardableResult
    public static func applyEquity(_ rows: [ServerSyncDTO.Equity], on db: any Database) async throws -> Int {
        var applied = 0
        for row in rows {
            let existing = try await EquityIdea.query(on: db)
                .filter(\.$symbol == row.symbol)
                .first()

            if let deletedAt = row.deletedAt {
                if let existing, deletedAt >= (existing.generatedAt ?? .distantPast) {
                    try await existing.delete(on: db)
                }
                applied += 1
                continue
            }

            if let existing {
                if let remoteGeneratedAt = row.generatedAt,
                   let localGeneratedAt = existing.generatedAt,
                   remoteGeneratedAt < localGeneratedAt
                {
                    applied += 1
                    continue
                }
                existing.thesisSummary = row.thesisSummary
                existing.syntheticScore = row.syntheticScore
                existing.factorBreakdown = row.factorBreakdown
                try await existing.save(on: db)
            } else {
                try await EquityIdea(
                    symbol: row.symbol,
                    thesisSummary: row.thesisSummary,
                    syntheticScore: row.syntheticScore,
                    factorBreakdown: row.factorBreakdown
                ).create(on: db)
            }
            applied += 1
        }
        return applied
    }
}
