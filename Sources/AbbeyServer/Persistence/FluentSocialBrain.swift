import AbbeyCore
import Fluent
import Foundation
import Vapor

/// Fluent-backed reputation engine. Algorithm lives in `ReputationMath`.
actor FluentSocialBrain {
    private let db: any Database
    private let eventBus: EventBus
    private let decay: @Sendable () -> Double
    private var scores: [String: Double] = [:]
    private(set) var lastPersistenceError: (any Error)?

    init(db: any Database, eventBus: EventBus, decay: @escaping @Sendable () -> Double) {
        self.db = db
        self.eventBus = eventBus
        self.decay = decay
    }

    func reputation(userId: String, guildId: String) -> Double {
        scores[ReputationMath.cacheKey(userId: userId, guildId: guildId)] ?? ReputationMath.defaultScore
    }

    func warmCache() async {
        do {
            let records = try await UserMemory.query(on: db).all()
            for record in records {
                scores[ReputationMath.cacheKey(userId: record.discordUserId, guildId: record.guildId)] = record.reputation
            }
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error
        }
    }

    func recordInteraction(userId: String, guildId: String, quality: Double, reason: String = "interaction") async {
        let k = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        let current = scores[k] ?? ReputationMath.defaultScore
        let updated = ReputationMath.blend(current: current, quality: quality, decay: decay())
        scores[k] = updated
        await persist(userId: userId, guildId: guildId, newValue: updated, delta: updated - current, reason: reason)
        await eventBus.publish(.reputationChanged(userId: userId, guildId: guildId, newValue: updated, reason: reason))
    }

    func penalize(userId: String, guildId: String, reason: String) async {
        let k = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        let current = scores[k] ?? ReputationMath.defaultScore
        let updated = ReputationMath.penalize(current: current)
        scores[k] = updated
        await persist(userId: userId, guildId: guildId, newValue: updated, delta: -ReputationMath.penaltyDelta, reason: reason)
        await eventBus.publish(.reputationChanged(userId: userId, guildId: guildId, newValue: updated, reason: reason))
    }

    private func persist(userId: String, guildId: String, newValue: Double, delta: Double, reason: String) async {
        do {
            let composite = ReputationMath.cacheKey(userId: userId, guildId: guildId)
            if let existing = try await UserMemory.query(on: db)
                .filter(\.$compositeKey == composite)
                .first()
            {
                existing.reputation = newValue
                existing.interactionCount += 1
                try await existing.save(on: db)
            } else {
                let record = UserMemory(
                    discordUserId: userId,
                    guildId: guildId,
                    reputation: newValue,
                    interactionCount: 1
                )
                try await record.create(on: db)
            }
            let event = ReputationEvent(userId: userId, guildId: guildId, delta: delta, reason: reason)
            try await event.create(on: db)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error
        }
    }
}
