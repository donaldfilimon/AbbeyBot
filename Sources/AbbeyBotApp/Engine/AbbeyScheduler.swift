import Foundation
import SwiftData
import AbbeyCore

/// Reply cooldown + channel consolidation for the desktop app.
actor AbbeyScheduler {
    private var cooldown = ReplyCooldownTracker()
    private var consolidationTask: Task<Void, Never>?

    private let modelContainer: ModelContainer
    private let eventBus: EventBus
    private let metrics: EngineMetrics
    private let cooldownSeconds: @Sendable () -> Double
    private let consolidationIntervalMinutes: @Sendable () -> Double

    init(
        modelContainer: ModelContainer,
        eventBus: EventBus,
        metrics: EngineMetrics,
        cooldownSeconds: @escaping @Sendable () -> Double,
        consolidationIntervalMinutes: @escaping @Sendable () -> Double
    ) {
        self.modelContainer = modelContainer
        self.eventBus = eventBus
        self.metrics = metrics
        self.cooldownSeconds = cooldownSeconds
        self.consolidationIntervalMinutes = consolidationIntervalMinutes
    }

    func isCoolingDown(userId: String, guildId: String) -> Bool {
        cooldown.isCoolingDown(userId: userId, guildId: guildId, cooldownSeconds: cooldownSeconds())
    }

    func markReplied(userId: String, guildId: String) {
        cooldown.markReplied(userId: userId, guildId: guildId)
    }

    func start() {
        consolidationTask?.cancel()
        consolidationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let intervalMinutes = self.consolidationIntervalMinutes()
                let nanoseconds = UInt64(max(intervalMinutes, 0.5) * 60 * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                do {
                    try await self.consolidateAllChannels()
                } catch {
                    NSLog("AbbeyBot: channel consolidation failed: %@", error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        consolidationTask?.cancel()
        consolidationTask = nil
    }

    func consolidateAllChannels() async throws {
        let context = ModelContext(modelContainer)
        let channels = try context.fetch(FetchDescriptor<ChannelContext>())
        var committedEvents: [(channelId: String, messageCount: Int)] = []

        for channel in channels {
            let channelId = channel.channelId
            let guildId = channel.guildId
            var descriptor = FetchDescriptor<GuildMessage>(
                predicate: #Predicate { $0.channelId == channelId && $0.guildId == guildId }
            )
            descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
            descriptor.fetchLimit = 50
            let recent = try context.fetch(descriptor)
            guard !recent.isEmpty else { continue }

            let countDescriptor = FetchDescriptor<GuildMessage>(
                predicate: #Predicate { $0.channelId == channelId && $0.guildId == guildId }
            )
            let totalMessageCount = try context.fetchCount(countDescriptor)

            let lines = recent.reversed().map {
                ChannelSummaryBuilder.Line(authorId: $0.authorId, content: $0.content)
            }
            channel.summary = ChannelSummaryBuilder.summarize(lines)
            channel.messageCount = totalMessageCount
            channel.updatedAt = .now

            committedEvents.append((channel.channelId, totalMessageCount))
        }

        try context.save()
        for event in committedEvents {
            await eventBus.publish(
                .channelContextConsolidated(
                    channelId: event.channelId,
                    messageCount: event.messageCount
                )
            )
        }
        metrics.recordConsolidation()
    }
}
