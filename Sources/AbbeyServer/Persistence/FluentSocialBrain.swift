import AbbeyCore
import Fluent
import Foundation
import Vapor

/// Fluent-backed reputation engine mirroring Desktop `SocialBrain`.
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
        scores[key(userId, guildId)] ?? 0.5
    }

    func warmCache() async {
        do {
            let records = try await UserMemory.query(on: db).all()
            for record in records {
                scores[key(record.discordUserId, record.guildId)] = record.reputation
            }
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error
        }
    }

    func recordInteraction(userId: String, guildId: String, quality: Double, reason: String = "interaction") async {
        let k = key(userId, guildId)
        let current = scores[k] ?? 0.5
        let alpha = decay()
        let updated = current * alpha + quality * (1 - alpha)
        scores[k] = updated
        await persist(userId: userId, guildId: guildId, newValue: updated, delta: updated - current, reason: reason)
        await eventBus.publish(.reputationChanged(userId: userId, guildId: guildId, newValue: updated, reason: reason))
    }

    func penalize(userId: String, guildId: String, reason: String) async {
        let k = key(userId, guildId)
        let current = scores[k] ?? 0.5
        let updated = max(0, current - 0.1)
        scores[k] = updated
        await persist(userId: userId, guildId: guildId, newValue: updated, delta: -0.1, reason: reason)
        await eventBus.publish(.reputationChanged(userId: userId, guildId: guildId, newValue: updated, reason: reason))
    }

    private func persist(userId: String, guildId: String, newValue: Double, delta: Double, reason: String) async {
        do {
            let composite = "\(guildId):\(userId)"
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

    private func key(_ userId: String, _ guildId: String) -> String { "\(guildId):\(userId)" }
}
