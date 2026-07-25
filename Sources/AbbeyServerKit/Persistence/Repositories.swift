import AbbeyCore
import Fluent
import Foundation
import Vapor

public enum MemoryForgetError: Error, Equatable {
    case noMemory
    case invalidIndex
}

public enum MemoryTombstoneError: Error, Equatable {
    case noMemory
}

public enum ChannelTombstoneError: Error, Equatable {
    case noChannel
}

public enum MemoryRepository {
    public static func appendFact(userId: String, guildId: String, fact: String, on db: any Database) async throws {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let composite = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        if let existing = try await UserMemory.query(on: db).filter(\.$compositeKey == composite).first() {
            // A remember after soft-delete resurrects the row so sync can ship a live update.
            if existing.deletedAt != nil {
                existing.deletedAt = nil
            }
            if !existing.facts.contains(trimmed) {
                existing.facts.append(trimmed)
            }
            try await existing.save(on: db)
        } else {
            let record = UserMemory(discordUserId: userId, guildId: guildId, facts: [trimmed])
            try await record.create(on: db)
        }
    }

    public static func forgetFact(userId: String, guildId: String, index: Int, on db: any Database) async throws {
        let composite = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        guard let memory = try await UserMemory.query(on: db).filter(\.$compositeKey == composite).first(),
              memory.deletedAt == nil
        else {
            throw MemoryForgetError.noMemory
        }
        let idx = index - 1
        guard memory.facts.indices.contains(idx) else {
            throw MemoryForgetError.invalidIndex
        }
        memory.facts.remove(at: idx)
        try await memory.save(on: db)
    }

    /// Soft-delete the whole user-memory row. Sets `deletedAt` and bumps `updatedAt` so
    /// incremental `?since=` pulls deliver the tombstone to desktop.
    public static func softDelete(userId: String, guildId: String, on db: any Database) async throws {
        let composite = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        guard let memory = try await UserMemory.query(on: db).filter(\.$compositeKey == composite).first(),
              memory.deletedAt == nil
        else {
            throw MemoryTombstoneError.noMemory
        }
        memory.deletedAt = Date()
        try await memory.save(on: db)
    }

    public static func facts(userId: String, guildId: String, on db: any Database) async throws -> [String] {
        let composite = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        guard let memory = try await UserMemory.query(on: db).filter(\.$compositeKey == composite).first(),
              memory.deletedAt == nil
        else {
            return []
        }
        return memory.facts
    }

    /// Full list (no `since`) hides tombstones. Incremental list (`since` set) includes
    /// rows whose `updatedAt` advanced — including soft-deletes — so SyncPull can remove them.
    public static func recent(limit: Int, since: Date? = nil, on db: any Database) async throws -> [UserMemory] {
        var query = UserMemory.query(on: db)
        if let since {
            query = query.filter(\.$updatedAt > since)
            return try await query.sort(\.$updatedAt, .descending).limit(limit).all()
        }
        // Fetch a wider window then drop tombstones in-process — Fluent optional-null
        // filters are awkward across SQLite/Postgres drivers, and list caps are small (≤500).
        let rows = try await query.sort(\.$updatedAt, .descending).limit(limit * 2).all()
        return Array(rows.filter { $0.deletedAt == nil }.prefix(limit))
    }

    public static func count(on db: any Database) async throws -> Int {
        try await UserMemory.query(on: db).all().filter { $0.deletedAt == nil }.count
    }
}

public enum ChannelRepository {
    public static func bump(channelId: String, guildId: String, on db: any Database) async throws {
        let composite = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
        if let existing = try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first() {
            if existing.deletedAt != nil {
                existing.deletedAt = nil
            }
            existing.messageCount += 1
            try await existing.save(on: db)
        } else {
            let row = ChannelContext(channelId: channelId, guildId: guildId, messageCount: 1)
            try await row.create(on: db)
        }
    }

    public static func summary(channelId: String, guildId: String, on db: any Database) async throws -> String {
        let composite = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
        guard let channel = try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first(),
              channel.deletedAt == nil
        else {
            return ""
        }
        return channel.summary
    }

    public static func messageCount(channelId: String, guildId: String, on db: any Database) async throws -> Int {
        let composite = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
        guard let channel = try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first(),
              channel.deletedAt == nil
        else {
            return 0
        }
        return channel.messageCount
    }

    public static func softDelete(channelId: String, guildId: String, on db: any Database) async throws {
        let composite = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
        guard let channel = try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first(),
              channel.deletedAt == nil
        else {
            throw ChannelTombstoneError.noChannel
        }
        channel.deletedAt = Date()
        try await channel.save(on: db)
    }

    public static func recent(limit: Int, since: Date? = nil, on db: any Database) async throws -> [ChannelContext] {
        var query = ChannelContext.query(on: db)
        if let since {
            query = query.filter(\.$updatedAt > since)
            return try await query.sort(\.$updatedAt, .descending).limit(limit).all()
        }
        let rows = try await query.sort(\.$updatedAt, .descending).limit(limit * 2).all()
        return Array(rows.filter { $0.deletedAt == nil }.prefix(limit))
    }

    public static func count(on db: any Database) async throws -> Int {
        try await ChannelContext.query(on: db).all().filter { $0.deletedAt == nil }.count
    }
}

public enum MessageRepository {
    public static func insert(
        discordMessageId: String,
        channelId: String,
        guildId: String,
        authorId: String,
        content: String,
        on db: any Database
    ) async throws {
        let row = GuildMessage(
            discordMessageId: discordMessageId,
            channelId: channelId,
            guildId: guildId,
            authorId: authorId,
            content: content
        )
        try await row.create(on: db)
    }

    public static func recent(channelId: String, guildId: String, limit: Int, on db: any Database) async throws -> [GuildMessage] {
        try await GuildMessage.query(on: db)
            .filter(\.$channelId == channelId)
            .filter(\.$guildId == guildId)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }

    public static func recent(limit: Int, since: Date? = nil, on db: any Database) async throws -> [GuildMessage] {
        var query = GuildMessage.query(on: db)
        if let since {
            query = query.filter(\.$createdAt > since)
        }
        return try await query
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }

    public static func count(on db: any Database) async throws -> Int {
        try await GuildMessage.query(on: db).count()
    }
}

public enum ReputationRepository {
    public static func recent(limit: Int, since: Date? = nil, on db: any Database) async throws -> [ReputationEvent] {
        var query = ReputationEvent.query(on: db)
        if let since {
            query = query.filter(\.$createdAt > since)
        }
        return try await query
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }

    public static func count(on db: any Database) async throws -> Int {
        try await ReputationEvent.query(on: db).count()
    }
}

public enum InteractionRepository {
    public static func log(
        commandName: String,
        userId: String,
        guildId: String,
        succeeded: Bool,
        latencyMs: Double,
        on db: any Database
    ) async throws {
        let row = InteractionLog(
            commandName: commandName,
            userId: userId,
            guildId: guildId,
            succeeded: succeeded,
            latencyMs: latencyMs
        )
        try await row.create(on: db)
    }

    public static func recent(limit: Int, since: Date? = nil, on db: any Database) async throws -> [InteractionLog] {
        var query = InteractionLog.query(on: db)
        if let since {
            query = query.filter(\.$createdAt > since)
        }
        return try await query
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }
}

public enum EquityRepository {
    public static func recent(limit: Int, since: Date? = nil, on db: any Database) async throws -> [EquityIdea] {
        var query = EquityIdea.query(on: db)
        if let since {
            query = query.filter(\.$generatedAt > since)
        }
        return try await query
            .sort(\.$generatedAt, .descending)
            .limit(limit)
            .all()
    }

    public static func count(on db: any Database) async throws -> Int {
        try await EquityIdea.query(on: db).count()
    }
}

public enum SyncStatusRepository {
    /// Upserts the single sync-status row (there is exactly one per server).
    public static func report(
        lastPullAt: Date?,
        lastPullError: String?,
        lastPushAt: Date?,
        lastPushError: String?,
        pendingPushCount: Int,
        on db: any Database
    ) async throws {
        let record = try await SyncStatusRecord.query(on: db).first() ?? SyncStatusRecord()
        record.lastPullAt = lastPullAt
        record.lastPullError = lastPullError
        record.lastPushAt = lastPushAt
        record.lastPushError = lastPushError
        record.pendingPushCount = pendingPushCount
        if record.id == nil {
            try await record.create(on: db)
        } else {
            try await record.save(on: db)
        }
    }

    /// The current sync status, or an empty (never-reported) default if no report has landed yet.
    public static func current(on db: any Database) async throws -> SyncStatusRecord {
        try await SyncStatusRecord.query(on: db).first() ?? SyncStatusRecord(pendingPushCount: 0)
    }
}

public struct StatusCounts: Content {
    public var users: Int
    public var channels: Int
    public var messages: Int
    public var reputationEvents: Int
    public var equityIdeas: Int
}

public enum StatusRepository {
    public static func counts(on db: any Database) async throws -> StatusCounts {
        async let users = MemoryRepository.count(on: db)
        async let channels = ChannelRepository.count(on: db)
        async let messages = MessageRepository.count(on: db)
        async let reputationEvents = ReputationRepository.count(on: db)
        async let equityIdeas = EquityRepository.count(on: db)
        return try await StatusCounts(
            users: users,
            channels: channels,
            messages: messages,
            reputationEvents: reputationEvents,
            equityIdeas: equityIdeas
        )
    }
}
