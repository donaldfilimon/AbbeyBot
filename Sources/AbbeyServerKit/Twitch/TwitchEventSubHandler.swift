import Foundation

/// A `channel.chat.message` EventSub notification reduced to what ingest needs.
public struct TwitchEventSubChatMessage: Equatable, Sendable {
    /// Chat author's Twitch login (`event.chatter_user_login`).
    public let chatterLogin: String
    /// Channel the message was sent in (`event.broadcaster_user_login`).
    public let broadcasterLogin: String
    /// Plain message text (`event.message.text`).
    public let text: String

    public init(chatterLogin: String, broadcasterLogin: String, text: String) {
        self.chatterLogin = chatterLogin
        self.broadcasterLogin = broadcasterLogin
        self.text = text
    }
}

/// Claim-honest per-event dispatch for Twitch EventSub notifications.
///
/// This does **not** auto-subscribe, talk to Helix, or implement PubSub. It classifies a
/// verified webhook delivery and, for `channel.chat.message` notifications with a parseable
/// payload, hands the chat event to the same ingest/reply path Twitch IRC uses
/// (`BotRuntime.handleTwitchChat`). Other notification types stay log-only.
public enum TwitchEventSubHandler {
    /// The only subscription type with a product side-effect so far.
    public static let chatMessageSubscriptionType = "channel.chat.message"

    public enum Outcome: Equatable, Sendable {
        /// `webhook_callback_verification` challenge (handled by the HTTP route, not here).
        case challenge
        /// Subscription was revoked by Twitch or the user.
        case revocation(subscriptionType: String, status: String?)
        /// `channel.chat.message` notification with a parseable payload — the route feeds it
        /// into the shared Twitch chat ingest/reply path.
        case notificationChatIngest(chat: TwitchEventSubChatMessage)
        /// Any other notification type we acknowledge and log (no product side-effect).
        case notificationAcknowledged(subscriptionType: String)
        /// Message type we don't model (still ack 2xx so Twitch stops retrying).
        case ignored(messageType: String, subscriptionType: String)
    }

    /// Classify a delivery. `messageType` is `Twitch-Eventsub-Message-Type`; `body` is the raw
    /// webhook JSON (used only to parse `channel.chat.message` payloads).
    public static func handle(
        messageType: String,
        subscriptionType: String?,
        subscriptionStatus: String?,
        body: Data? = nil
    ) -> Outcome {
        let type = messageType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sub = (subscriptionType ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "webhook_callback_verification":
            return .challenge
        case "revocation":
            return .revocation(subscriptionType: sub.isEmpty ? "unknown" : sub, status: subscriptionStatus)
        case "notification":
            if sub == chatMessageSubscriptionType, let body, let chat = parseChatMessage(from: body) {
                return .notificationChatIngest(chat: chat)
            }
            return .notificationAcknowledged(subscriptionType: sub.isEmpty ? "unknown" : sub)
        default:
            return .ignored(messageType: type.isEmpty ? "unknown" : type, subscriptionType: sub.isEmpty ? "unknown" : sub)
        }
    }

    /// Parse a `channel.chat.message` webhook body. Returns nil when the payload is missing
    /// required fields or the text is empty — callers then fall back to log-only ack.
    public static func parseChatMessage(from body: Data) -> TwitchEventSubChatMessage? {
        guard let decoded = try? JSONDecoder().decode(ChatMessageWebhookBody.self, from: body),
              let event = decoded.event
        else { return nil }
        let chatter = (event.chatterUserLogin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let broadcaster = (event.broadcasterUserLogin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (event.message?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatter.isEmpty, !broadcaster.isEmpty, !text.isEmpty else { return nil }
        return TwitchEventSubChatMessage(chatterLogin: chatter, broadcasterLogin: broadcaster, text: text)
    }

    public static func logLine(for outcome: Outcome) -> String {
        switch outcome {
        case .challenge:
            return "Twitch EventSub: challenge (route echoes body)"
        case .revocation(let subscriptionType, let status):
            return "Twitch EventSub: revocation type=\(subscriptionType) status=\(status ?? "unknown")"
        case .notificationChatIngest(let chat):
            return "Twitch EventSub: \(chatMessageSubscriptionType) from \(chat.chatterLogin) in #\(chat.broadcasterLogin) — ingesting"
        case .notificationAcknowledged(let subscriptionType):
            return "Twitch EventSub: notification type=\(subscriptionType) acknowledged (no product side-effect)"
        case .ignored(let messageType, let subscriptionType):
            return "Twitch EventSub: ignored messageType=\(messageType) subscriptionType=\(subscriptionType)"
        }
    }
}

private struct ChatMessageWebhookBody: Decodable {
    struct Event: Decodable {
        struct Message: Decodable {
            var text: String?
        }

        var chatterUserLogin: String?
        var broadcasterUserLogin: String?
        var message: Message?

        enum CodingKeys: String, CodingKey {
            case chatterUserLogin = "chatter_user_login"
            case broadcasterUserLogin = "broadcaster_user_login"
            case message
        }
    }

    var event: Event?
}
