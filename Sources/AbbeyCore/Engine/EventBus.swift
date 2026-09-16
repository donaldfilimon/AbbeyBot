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
    /// Twitch EventSub `stream.online` / `stream.offline` — operator status only.
    case twitchStreamLifecycle(broadcasterLogin: String, isLive: Bool)
    /// Twitch EventSub `channel.follow` / `channel.subscribe` / `channel.cheer`. Emitted once
    /// per genuinely new delivery — a redelivered webhook dedupes upstream and publishes
    /// nothing. `kind` is the EventSub subscription type as Twitch sent it.
    case twitchChannelSocial(
        kind: String,
        broadcasterLogin: String,
        actorLogin: String,
        detail: String
    )

    /// Operator-facing one-liner for dashboards (not `String(describing:)`).
    public var displayDescription: String {
        switch self {
        case .messageIngested(let channelId, let guildId, let authorId):
            return "Ingested message from \(authorId) in channel \(channelId) (\(guildId))"
        case .reputationChanged(let userId, _, let newValue, let reason):
            return "Reputation \(userId) → \(String(format: "%.2f", newValue)) (\(reason))"
        case .channelContextConsolidated(let channelId, let messageCount):
            return "Consolidated channel \(channelId) (\(messageCount) msgs)"
        case .personaSwitched(let name):
            return "Persona → \(name)"
        case .destructiveActionRequested(let kind, let targetUserId, _):
            return "Confirm \(kind.rawValue) for \(targetUserId)?"
        case .destructiveActionConfirmed(let kind, let targetUserId, _):
            return "Confirmed \(kind.rawValue) for \(targetUserId)"
        case .destructiveActionCancelled(let kind, let targetUserId):
            return "Cancelled \(kind.rawValue) for \(targetUserId)"
        case .equityIdeaGenerated(let symbol):
            return "Equity idea \(symbol)"
        case .inferenceProviderFailed(let mode, let message):
            return "Inference failed (\(mode.rawValue)): \(message)"
        case .twitchStreamLifecycle(let broadcasterLogin, let isLive):
            return isLive
                ? "Twitch stream live: #\(broadcasterLogin)"
                : "Twitch stream offline: #\(broadcasterLogin)"
        case .twitchChannelSocial(let kind, let broadcasterLogin, let actorLogin, let detail):
            return "Twitch \(kind) #\(broadcasterLogin) by \(actorLogin): \(detail)"
        }
    }
}

public enum DestructiveAction: String, Sendable, CaseIterable {
    case purge, kick, ban

    /// Removing a member cannot be undone by the bot, so no setting may skip the sheet.
    public var alwaysRequiresConfirmation: Bool {
        switch self {
        case .purge: return false
        case .kick, .ban: return true
        }
    }
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
