import Foundation

/// Everything that happens inside the engine — message ingest, reputation changes,
/// persona switches, confirmation prompts — flows through here as a single ordered
/// stream so the UI layer can subscribe once instead of wiring up N delegate callbacks.
public enum AbbeyEvent: Sendable {
    case messageIngested(channelId: String, guildId: String, authorId: String)
    case reputationChanged(userId: String, guildId: String, newValue: Double, reason: String)
    case channelContextConsolidated(channelId: String, messageCount: Int)
    case personaSwitched(to: String)
    case destructiveActionRequested(kind: DestructiveAction, targetUserId: String, guildId: String)
    case destructiveActionConfirmed(kind: DestructiveAction, targetUserId: String, guildId: String)
    case destructiveActionCancelled(kind: DestructiveAction, targetUserId: String)
    case equityIdeaGenerated(symbol: String)
    case inferenceProviderFailed(mode: InferenceMode, message: String)
}

public enum DestructiveAction: String, Sendable, CaseIterable {
    case purge, kick, ban
}

/// Actor-isolated publisher over `AsyncStream`. Multiple UI subscribers each get their
/// own stream via `subscribe()` — this is a broadcast, not a single-consumer queue.
public actor EventBus {
    private var continuations: [UUID: AsyncStream<AbbeyEvent>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<AbbeyEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AbbeyEvent>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unregister(id) }
        }
        return stream
    }

    public func publish(_ event: AbbeyEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func unregister(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
