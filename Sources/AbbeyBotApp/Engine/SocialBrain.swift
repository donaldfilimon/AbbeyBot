import Foundation
import SwiftData
import AbbeyCore

/// Reputation engine backed by SwiftData. Algorithm lives in `ReputationMath`.
actor SocialBrain {
    private let modelContainer: ModelContainer
    private let eventBus: EventBus
    private let decay: @Sendable () -> Double
    private var scores: [String: Double] = [:]
    private(set) var lastPersistenceError: (any Error)?

    init(modelContainer: ModelContainer, eventBus: EventBus, decay: @escaping @Sendable () -> Double) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.decay = decay
    }

    func reputation(userId: String, guildId: String) -> Double {
        scores[ReputationMath.cacheKey(userId: userId, guildId: guildId)] ?? ReputationMath.defaultScore
    }

    func warmCache() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<UserMemory>()
        guard let records = try? context.fetch(descriptor) else { return }
        for record in records {
            scores[ReputationMath.cacheKey(userId: record.discordUserId, guildId: record.guildId)] = record.reputation
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
        let context = ModelContext(modelContainer)
        do {
            let descriptor = FetchDescriptor<UserMemory>(
                predicate: #Predicate { $0.discordUserId == userId && $0.guildId == guildId }
            )
            if let existing = try context.fetch(descriptor).first {
                existing.reputation = newValue
                existing.interactionCount += 1
                existing.updatedAt = .now
            } else {
                let record = UserMemory(discordUserId: userId, guildId: guildId, reputation: newValue, interactionCount: 1)
                context.insert(record)
            }
            context.insert(ReputationEvent(userId: userId, guildId: guildId, delta: delta, reason: reason))
            try context.save()
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error
        }
    }
}
