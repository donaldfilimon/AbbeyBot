import AbbeyCore
import Fluent
import Foundation
import Vapor

enum MemoryForgetError: Error, Equatable {
    case noMemory
    case invalidIndex
}

enum MemoryRepository {
    static func appendFact(userId: String, guildId: String, fact: String, on db: any Database) async throws {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let composite = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        if let existing = try await UserMemory.query(on: db).filter(\.$compositeKey == composite).first() {
            if !existing.facts.contains(trimmed) {
                existing.facts.append(trimmed)
                try await existing.save(on: db)
            }
        } else {
            let record = UserMemory(discordUserId: userId, guildId: guildId, facts: [trimmed])
            try await record.create(on: db)
        }
    }

    static func forgetFact(userId: String, guildId: String, index: Int, on db: any Database) async throws {
        let composite = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        guard let memory = try await UserMemory.query(on: db).filter(\.$compositeKey == composite).first() else {
            throw MemoryForgetError.noMemory
        }
        let idx = index - 1
        guard memory.facts.indices.contains(idx) else {
            throw MemoryForgetError.invalidIndex
        }
        memory.facts.remove(at: idx)
        try await memory.save(on: db)
    }

    static func facts(userId: String, guildId: String, on db: any Database) async throws -> [String] {
        let composite = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        return try await UserMemory.query(on: db).filter(\.$compositeKey == composite).first()?.facts ?? []
    }

    static func recent(limit: Int, on db: any Database) async throws -> [UserMemory] {
        try await UserMemory.query(on: db).sort(\.$updatedAt, .descending).limit(limit).all()
    }

    static func count(on db: any Database) async throws -> Int {
        try await UserMemory.query(on: db).count()
    }
}

enum ChannelRepository {
    static func bump(channelId: String, guildId: String, on db: any Database) async throws {
        let composite = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
        if let existing = try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first() {
            existing.messageCount += 1
            try await existing.save(on: db)
        } else {
            let row = ChannelContext(channelId: channelId, guildId: guildId, messageCount: 1)
            try await row.create(on: db)
        }
    }

    static func summary(channelId: String, guildId: String, on db: any Database) async throws -> String {
        let composite = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
        return try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first()?.summary ?? ""
    }

    static func messageCount(channelId: String, guildId: String, on db: any Database) async throws -> Int {
        let composite = ReputationMath.channelKey(channelId: channelId, guildId: guildId)
        return try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first()?.messageCount ?? 0
    }

    static func recent(limit: Int, on db: any Database) async throws -> [ChannelContext] {
        try await ChannelContext.query(on: db).sort(\.$updatedAt, .descending).limit(limit).all()
    }

    static func count(on db: any Database) async throws -> Int {
        try await ChannelContext.query(on: db).count()
    }
}

enum MessageRepository {
    static func insert(
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

    static func recent(channelId: String, guildId: String, limit: Int, on db: any Database) async throws -> [GuildMessage] {
        try await GuildMessage.query(on: db)
            .filter(\.$channelId == channelId)
            .filter(\.$guildId == guildId)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }

    static func recent(limit: Int, on db: any Database) async throws -> [GuildMessage] {
        try await GuildMessage.query(on: db)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }

    static func count(on db: any Database) async throws -> Int {
        try await GuildMessage.query(on: db).count()
    }
}

enum ReputationRepository {
    static func recent(limit: Int, on db: any Database) async throws -> [ReputationEvent] {
        try await ReputationEvent.query(on: db)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }

    static func count(on db: any Database) async throws -> Int {
        try await ReputationEvent.query(on: db).count()
    }
}

enum InteractionRepository {
    static func log(
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

    static func recent(limit: Int, on db: any Database) async throws -> [InteractionLog] {
        try await InteractionLog.query(on: db)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
    }
}

enum EquityRepository {
    static func recent(limit: Int, on db: any Database) async throws -> [EquityIdea] {
        try await EquityIdea.query(on: db)
            .sort(\.$generatedAt, .descending)
            .limit(limit)
            .all()
    }

    static func count(on db: any Database) async throws -> Int {
        try await EquityIdea.query(on: db).count()
    }
}

struct StatusCounts: Content {
    var users: Int
    var channels: Int
    var messages: Int
    var reputationEvents: Int
    var equityIdeas: Int
}

enum StatusRepository {
    static func counts(on db: any Database) async throws -> StatusCounts {
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
