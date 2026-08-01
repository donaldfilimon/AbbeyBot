import Foundation
import SwiftData
import AbbeyCore

/// Reputation engine backed by SwiftData. Algorithm lives in `ReputationMath`.
actor SocialBrain {
    typealias SaveContext = @Sendable (ModelContext) throws -> Void

    private let modelContainer: ModelContainer
    private let eventBus: EventBus
    private let decay: @Sendable () -> Double
    private let saveContext: SaveContext
    private var scores: [String: Double] = [:]
    private(set) var lastPersistenceError: (any Error)?

    init(
        modelContainer: ModelContainer,
        eventBus: EventBus,
        decay: @escaping @Sendable () -> Double,
        saveContext: @escaping SaveContext = { try $0.save() }
    ) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.decay = decay
        self.saveContext = saveContext
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
        guard persist(userId: userId, guildId: guildId, newValue: updated, delta: updated - current, reason: reason) else {
            return
        }
        scores[k] = updated
        await eventBus.publish(.reputationChanged(userId: userId, guildId: guildId, newValue: updated, reason: reason))
    }

    func penalize(userId: String, guildId: String, reason: String) async {
        let k = ReputationMath.cacheKey(userId: userId, guildId: guildId)
        let current = scores[k] ?? ReputationMath.defaultScore
        let updated = ReputationMath.penalize(current: current)
        guard persist(userId: userId, guildId: guildId, newValue: updated, delta: -ReputationMath.penaltyDelta, reason: reason) else {
            return
        }
        scores[k] = updated
        await eventBus.publish(.reputationChanged(userId: userId, guildId: guildId, newValue: updated, reason: reason))
    }

    @discardableResult
    private func persist(userId: String, guildId: String, newValue: Double, delta: Double, reason: String) -> Bool {
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
            try saveContext(context)
            lastPersistenceError = nil
            return true
        } catch {
            context.rollback()
            lastPersistenceError = error
            return false
        }
    }
}
