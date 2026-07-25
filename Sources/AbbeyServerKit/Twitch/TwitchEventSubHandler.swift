import Foundation

/// Claim-honest per-event dispatch for Twitch EventSub notifications.
///
/// This does **not** auto-subscribe, talk to Helix, or implement PubSub. It only classifies
/// a verified webhook delivery so the HTTP route can log/ack with a typed outcome instead of
/// a generic "deferred" line. Business side-effects (ingest, persona reply) stay out until a
/// live callback + subscription type is wired on purpose.
public enum TwitchEventSubHandler {
    public enum Outcome: Equatable, Sendable {
        /// `webhook_callback_verification` challenge (handled by the HTTP route, not here).
        case challenge
        /// Subscription was revoked by Twitch or the user.
        case revocation(subscriptionType: String, status: String?)
        /// A known notification type we acknowledge and log (no product side-effect yet).
        case notificationAcknowledged(subscriptionType: String)
        /// Message type we don't model (still ack 2xx so Twitch stops retrying).
        case ignored(messageType: String, subscriptionType: String)
    }

    /// Classify a delivery. `messageType` is `Twitch-Eventsub-Message-Type`.
    public static func handle(
        messageType: String,
        subscriptionType: String?,
        subscriptionStatus: String?
    ) -> Outcome {
        let type = messageType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sub = (subscriptionType ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "webhook_callback_verification":
            return .challenge
        case "revocation":
            return .revocation(subscriptionType: sub.isEmpty ? "unknown" : sub, status: subscriptionStatus)
        case "notification":
            return .notificationAcknowledged(subscriptionType: sub.isEmpty ? "unknown" : sub)
        default:
            return .ignored(messageType: type.isEmpty ? "unknown" : type, subscriptionType: sub.isEmpty ? "unknown" : sub)
        }
    }

    public static func logLine(for outcome: Outcome) -> String {
        switch outcome {
        case .challenge:
            return "Twitch EventSub: challenge (route echoes body)"
        case .revocation(let subscriptionType, let status):
            return "Twitch EventSub: revocation type=\(subscriptionType) status=\(status ?? "unknown")"
        case .notificationAcknowledged(let subscriptionType):
            return "Twitch EventSub: notification type=\(subscriptionType) acknowledged (no product side-effect)"
        case .ignored(let messageType, let subscriptionType):
            return "Twitch EventSub: ignored messageType=\(messageType) subscriptionType=\(subscriptionType)"
        }
    }
}
