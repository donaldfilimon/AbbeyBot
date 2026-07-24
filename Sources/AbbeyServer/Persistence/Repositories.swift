import Fluent
import Foundation
import Vapor

enum MemoryRepository {
    static func appendFact(userId: String, guildId: String, fact: String, on db: any Database) async throws {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let composite = "\(guildId):\(userId)"
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

    static func forgetFact(userId: String, guildId: String, index: Int, on db: any Database) async throws -> String {
        let composite = "\(guildId):\(userId)"
        guard let memory = try await UserMemory.query(on: db).filter(\.$compositeKey == composite).first() else {
            return "No memory for that user."
        }
        let idx = index - 1
        guard memory.facts.indices.contains(idx) else { return "Invalid fact index." }
        memory.facts.remove(at: idx)
        try await memory.save(on: db)
        return "Forgot fact #\(index)."
    }

    static func facts(userId: String, guildId: String, on db: any Database) async throws -> [String] {
        let composite = "\(guildId):\(userId)"
        return try await UserMemory.query(on: db).filter(\.$compositeKey == composite).first()?.facts ?? []
    }
}

enum ChannelRepository {
    static func bump(channelId: String, guildId: String, on db: any Database) async throws {
        let composite = "\(guildId):\(channelId)"
        if let existing = try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first() {
            existing.messageCount += 1
            try await existing.save(on: db)
        } else {
            let row = ChannelContext(channelId: channelId, guildId: guildId, messageCount: 1)
            try await row.create(on: db)
        }
    }

    static func summary(channelId: String, guildId: String, on db: any Database) async throws -> String {
        let composite = "\(guildId):\(channelId)"
        return try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first()?.summary ?? ""
    }

    static func messageCount(channelId: String, guildId: String, on db: any Database) async throws -> Int {
        let composite = "\(guildId):\(channelId)"
        return try await ChannelContext.query(on: db).filter(\.$compositeKey == composite).first()?.messageCount ?? 0
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

enum StatusRepository {
    static func counts(on db: any Database) async throws -> (users: Int, channels: Int, messages: Int, reputationEvents: Int) {
        let users = try await UserMemory.query(on: db).count()
        let channels = try await ChannelContext.query(on: db).count()
        let messages = try await MessageRepository.count(on: db)
        let reputationEvents = try await ReputationRepository.count(on: db)
        return (users, channels, messages, reputationEvents)
    }
}
