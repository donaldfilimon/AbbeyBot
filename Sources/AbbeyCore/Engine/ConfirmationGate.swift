import Foundation

/// Human-in-the-loop gate for purge/kick/ban. Nothing in this app executes a
/// destructive action directly — every call site routes through
/// `request(kind:targetUserId:guildId:reason:)`, which suspends until a UI confirmation
/// sheet resolves the pending request. Only a purge may skip the sheet, and only when
/// `AppConfig.confirmationRequiredForDestructiveActions` is false; a kick or ban always
/// waits for a human (decided 2026-09-16).
///
/// Every approved request publishes `.destructiveActionConfirmed`, including an immediate
/// approval: the action goes ahead either way, and subscribers (metrics, the moderation reward)
/// key on that event.
public actor ConfirmationGate {
    public struct PendingRequest: Identifiable, Sendable {
        public let id: UUID
        public let kind: DestructiveAction
        public let targetUserId: String
        public let guildId: String
        public let reason: String
        public let requestedAt: Date
    }

    private var pending: [UUID: CheckedContinuation<Bool, Never>] = [:]
    public private(set) var queue: [PendingRequest] = []

    private let requireConfirmation: @Sendable () -> Bool
    private let eventBus: EventBus

    public init(eventBus: EventBus, requireConfirmation: @escaping @Sendable () -> Bool) {
        self.eventBus = eventBus
        self.requireConfirmation = requireConfirmation
    }

    /// Suspends until the pending request is confirmed or cancelled from the UI.
    /// Returns `true` if the caller should proceed with the destructive action.
    ///
    /// The queue is updated *before* the event is published so UI subscribers that
    /// react to `.destructiveActionRequested` always see a non-empty `queue`.
    public func request(kind: DestructiveAction, targetUserId: String, guildId: String, reason: String) async -> Bool {
        guard requireConfirmation() || kind.alwaysRequiresConfirmation else {
            await eventBus.publish(.destructiveActionRequested(kind: kind, targetUserId: targetUserId, guildId: guildId))
            await eventBus.publish(.destructiveActionConfirmed(kind: kind, targetUserId: targetUserId, guildId: guildId))
            return true
        }

        let item = PendingRequest(
            id: UUID(),
            kind: kind,
            targetUserId: targetUserId,
            guildId: guildId,
            reason: reason,
            requestedAt: .now
        )
        queue.append(item)
        await eventBus.publish(.destructiveActionRequested(kind: kind, targetUserId: targetUserId, guildId: guildId))

        return await withCheckedContinuation { continuation in
            pending[item.id] = continuation
        }
    }

    /// Called by the confirmation sheet when the user taps Confirm.
    public func confirm(_ id: UUID) async {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let item = queue.first(where: { $0.id == id }) {
            queue.removeAll { $0.id == id }
            await eventBus.publish(.destructiveActionConfirmed(kind: item.kind, targetUserId: item.targetUserId, guildId: item.guildId))
        }
        continuation.resume(returning: true)
    }

    /// Called by the confirmation sheet when the user taps Cancel, or dismisses it.
    public func cancel(_ id: UUID) async {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let item = queue.first(where: { $0.id == id }) {
            queue.removeAll { $0.id == id }
            await eventBus.publish(.destructiveActionCancelled(kind: item.kind, targetUserId: item.targetUserId))
        }
        continuation.resume(returning: false)
    }
}
