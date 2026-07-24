import Foundation
import SwiftData
import AbbeyCore

/// Reputation engine. Ported from the Vapor/Fluent version (references/brain.md) onto
/// SwiftData: instead of taking a `Database` parameter per call, this actor owns a
/// private `ModelContext` constructed from the shared `ModelContainer` — `ModelContext`
/// isn't `Sendable` and isn't meant to be shared across concurrency domains, so each
/// actor/background task that needs one creates its own from the same container
/// (this is the documented pattern, not a shortcut).
///
/// The reputation-persistence bug category noted in memory (/areas/discord-abbey-skill.md)
/// was upstream Fluent model wiring, not a SwiftData-specific issue; this rewrite keeps
/// the same "cache first, persist async, tolerate write failure" shape as the reference
/// but no longer swallows persistence failures silently — see `lastPersistenceError`.
public actor SocialBrain {
    private let modelContainer: ModelContainer
    private let eventBus: EventBus
    private let decay: @Sendable () -> Double

    /// In-memory cache, authoritative for reads within this process. Backed by
    /// `ReputationEvent` rows for audit history and cross-launch reconstruction.
    private var scores: [String: Double] = [:]
    public private(set) var lastPersistenceError: (any Error)?

    public init(modelContainer: ModelContainer, eventBus: EventBus, decay: @escaping @Sendable () -> Double) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.decay = decay
    }

    public func reputation(userId: String, guildId: String) -> Double {
        scores[key(userId, guildId)] ?? 0.5
    }

    /// Loads cached scores from the most recent `UserMemory.reputation` per user/guild,
    /// so a relaunch doesn't reset everyone to the 0.5 default. Call once at startup.
    public func warmCache() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<UserMemory>()
        guard let records = try? context.fetch(descriptor) else { return }
        for record in records {
            scores[key(record.discordUserId, record.guildId)] = record.reputation
        }
    }

    public func recordInteraction(userId: String, guildId: String, quality: Double, reason: String = "interaction") async {
        let k = key(userId, guildId)
        let current = scores[k] ?? 0.5
        let alpha = decay()
        let updated = current * alpha + quality * (1 - alpha)
        scores[k] = updated

        await persist(userId: userId, guildId: guildId, newValue: updated, delta: updated - current, reason: reason)
        await eventBus.publish(.reputationChanged(userId: userId, guildId: guildId, newValue: updated, reason: reason))
    }

    public func penalize(userId: String, guildId: String, reason: String) async {
        let k = key(userId, guildId)
        let current = scores[k] ?? 0.5
        let updated = max(0, current - 0.1)
        scores[k] = updated

        await persist(userId: userId, guildId: guildId, newValue: updated, delta: -0.1, reason: reason)
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

    private func key(_ userId: String, _ guildId: String) -> String { "\(guildId):\(userId)" }
}
