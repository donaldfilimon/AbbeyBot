import Foundation
import SwiftData

/// Owns the two time-driven behaviors described in /areas/abbey-bot.md:
///   - per-user reply cooldown (ABBEY_REPLY_COOLDOWN_SECONDS)
///   - channel memory consolidation on a fixed interval (ABBEY_MEMORY_CONSOLIDATION_INTERVAL_MIN)
///
/// This is a plain actor rather than `Timer`/`DispatchSourceTimer` so it's testable
/// without a run loop, and so cooldown checks are just dictionary reads with no
/// background thread of their own — only consolidation needs an actual sleeping task.
public actor AbbeyScheduler {
    private var lastReplyAt: [String: Date] = [:]     // key: "guildId:userId"
    private var consolidationTask: Task<Void, Never>?

    private let modelContainer: ModelContainer
    private let eventBus: EventBus
    private let metrics: EngineMetrics
    private let cooldownSeconds: @Sendable () -> Double
    private let consolidationIntervalMinutes: @Sendable () -> Double

    public init(
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

    /// Returns `true` if the user is currently cooling down and Abbey should skip
    /// replying this turn. Does not itself record a new reply — call `markReplied`
    /// after actually sending one.
    public func isCoolingDown(userId: String, guildId: String) -> Bool {
        guard let last = lastReplyAt[key(userId, guildId)] else { return false }
        return Date.now.timeIntervalSince(last) < cooldownSeconds()
    }

    public func markReplied(userId: String, guildId: String) {
        lastReplyAt[key(userId, guildId)] = .now
    }

    /// Starts the recurring consolidation loop. Idempotent — calling this twice
    /// cancels the previous loop first, so config changes (interval edited in
    /// Settings) can just call `start()` again.
    public func start() {
        consolidationTask?.cancel()
        consolidationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let intervalMinutes = await self.currentConsolidationIntervalMinutes()
                let nanoseconds = UInt64(max(intervalMinutes, 0.5) * 60 * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await self.consolidateAllChannels()
            }
        }
    }

    public func stop() {
        consolidationTask?.cancel()
        consolidationTask = nil
    }

    /// Recomputes each `ChannelContext.summary` from the most recent messages in that
    /// channel. The summarization itself is intentionally simple (most-recent-N,
    /// truncated) here — swap in `InferenceProvider` for a real abstractive summary
    /// once one is wired up; this keeps the scheduler functional with zero model calls
    /// in `.deterministicFloor` mode.
    public func consolidateAllChannels() async {
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

            let summaryLines = recent.reversed().map { "\($0.authorId): \($0.content.prefix(120))" }
            channel.summary = summaryLines.joined(separator: "\n")
            channel.messageCount = recent.count
            channel.updatedAt = .now

            await eventBus.publish(.channelContextConsolidated(channelId: channel.channelId, messageCount: recent.count))
        }

        try? context.save()
        metrics.recordConsolidation()
    }

    private func key(_ userId: String, _ guildId: String) -> String { "\(guildId):\(userId)" }

    private func currentConsolidationIntervalMinutes() -> Double {
        consolidationIntervalMinutes()
    }
}
