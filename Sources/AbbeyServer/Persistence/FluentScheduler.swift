import AbbeyCore
import Fluent
import Foundation
import Vapor

/// Reply cooldown + channel summary consolidation for the headless server.
actor FluentScheduler {
    private var lastReplyAt: [String: Date] = [:]
    private var consolidationTask: Task<Void, Never>?
    private let db: any Database
    private let logger: Logger
    private let eventBus: EventBus
    private let metrics: EngineMetrics
    private let cooldownSeconds: @Sendable () -> Double
    private let consolidationIntervalMinutes: @Sendable () -> Double

    init(
        db: any Database,
        logger: Logger,
        eventBus: EventBus,
        metrics: EngineMetrics,
        cooldownSeconds: @escaping @Sendable () -> Double,
        consolidationIntervalMinutes: @escaping @Sendable () -> Double
    ) {
        self.db = db
        self.logger = logger
        self.eventBus = eventBus
        self.metrics = metrics
        self.cooldownSeconds = cooldownSeconds
        self.consolidationIntervalMinutes = consolidationIntervalMinutes
    }

    func isCoolingDown(userId: String, guildId: String) -> Bool {
        guard let last = lastReplyAt[key(userId, guildId)] else { return false }
        return Date.now.timeIntervalSince(last) < cooldownSeconds()
    }

    func markReplied(userId: String, guildId: String) {
        lastReplyAt[key(userId, guildId)] = .now
    }

    func start() {
        consolidationTask?.cancel()
        consolidationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let minutes = self.consolidationIntervalMinutes()
                let nanoseconds = UInt64(max(minutes, 0.5) * 60 * 1_000_000_000)
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
        do {
            let channels = try await ChannelContext.query(on: db).all()
            for channel in channels {
                let recent = try await MessageRepository.recent(
                    channelId: channel.channelId,
                    guildId: channel.guildId,
                    limit: 50,
                    on: db
                )
                guard !recent.isEmpty else { continue }
                let summaryLines = recent.reversed().map { "\($0.authorId): \($0.content.prefix(120))" }
                channel.summary = summaryLines.joined(separator: "\n")
                channel.messageCount = recent.count
                try await channel.save(on: db)
                await eventBus.publish(
                    .channelContextConsolidated(channelId: channel.channelId, messageCount: recent.count)
                )
            }
            metrics.recordConsolidation()
        } catch {
            logger.warning("Channel consolidation failed: \(String(reflecting: error))")
        }
    }

    private func key(_ userId: String, _ guildId: String) -> String { "\(guildId):\(userId)" }
}
