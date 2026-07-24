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
                await self.consolidateAllChannels()
            }
        }
    }

    func stop() {
        consolidationTask?.cancel()
        consolidationTask = nil
    }

    func consolidateAllChannels() async {
        let context = ModelContext(modelContainer)
        guard let channels = try? context.fetch(FetchDescriptor<ChannelContext>()) else { return }

        for channel in channels {
            let channelId = channel.channelId
            let guildId = channel.guildId
            var descriptor = FetchDescriptor<GuildMessage>(
                predicate: #Predicate { $0.channelId == channelId && $0.guildId == guildId }
            )
            descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
            descriptor.fetchLimit = 50
            guard let recent = try? context.fetch(descriptor), !recent.isEmpty else { continue }

            let lines = recent.reversed().map {
                ChannelSummaryBuilder.Line(authorId: $0.authorId, content: $0.content)
            }
            channel.summary = ChannelSummaryBuilder.summarize(lines)
            channel.messageCount = recent.count
            channel.updatedAt = .now

            await eventBus.publish(.channelContextConsolidated(channelId: channel.channelId, messageCount: recent.count))
        }

        try? context.save()
        metrics.recordConsolidation()
    }
}
