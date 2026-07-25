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

/// A `stream.online` / `stream.offline` EventSub notification reduced to operator status.
public struct TwitchEventSubStreamLifecycle: Equatable, Sendable {
    /// Broadcaster login (`event.broadcaster_user_login`).
    public let broadcasterLogin: String
    /// `true` for `stream.online`, `false` for `stream.offline`.
    public let isLive: Bool

    public init(broadcasterLogin: String, isLive: Bool) {
        self.broadcasterLogin = broadcasterLogin
        self.isLive = isLive
    }
}

/// Claim-honest per-event dispatch for Twitch EventSub notifications.
///
/// This does **not** talk to Helix or implement PubSub. It classifies a verified webhook
/// delivery and, for known subscription types with a parseable payload, hands the event to
/// the shared Twitch runtime path:
/// - `channel.chat.message` → `BotRuntime.handleTwitchChat`
/// - `stream.online` / `stream.offline` → `BotRuntime.handleTwitchStreamLifecycle`
/// Other notification types stay log-only.
public enum TwitchEventSubHandler {
    public static let chatMessageSubscriptionType = "channel.chat.message"
    public static let streamOnlineSubscriptionType = "stream.online"
    public static let streamOfflineSubscriptionType = "stream.offline"

    public enum Outcome: Equatable, Sendable {
        /// `webhook_callback_verification` challenge (handled by the HTTP route, not here).
        case challenge
        /// Subscription was revoked by Twitch or the user.
        case revocation(subscriptionType: String, status: String?)
        /// `channel.chat.message` notification with a parseable payload — the route feeds it
        /// into the shared Twitch chat ingest/reply path.
        case notificationChatIngest(chat: TwitchEventSubChatMessage)
        /// `stream.online` with a parseable broadcaster — updates runtime stream-live state.
        case notificationStreamOnline(lifecycle: TwitchEventSubStreamLifecycle)
        /// `stream.offline` with a parseable broadcaster — updates runtime stream-live state.
        case notificationStreamOffline(lifecycle: TwitchEventSubStreamLifecycle)
        /// Any other notification type we acknowledge and log (no product side-effect).
        case notificationAcknowledged(subscriptionType: String)
        /// Message type we don't model (still ack 2xx so Twitch stops retrying).
        case ignored(messageType: String, subscriptionType: String)
    }

    /// Classify a delivery. `messageType` is `Twitch-Eventsub-Message-Type`; `body` is the raw
    /// webhook JSON (used to parse chat and stream-lifecycle payloads).
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
            if sub == streamOnlineSubscriptionType, let body,
               let lifecycle = parseStreamLifecycle(from: body, isLive: true)
            {
                return .notificationStreamOnline(lifecycle: lifecycle)
            }
            if sub == streamOfflineSubscriptionType, let body,
               let lifecycle = parseStreamLifecycle(from: body, isLive: false)
            {
                return .notificationStreamOffline(lifecycle: lifecycle)
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

    /// Parse a `stream.online` / `stream.offline` webhook body. Returns nil when the
    /// broadcaster login is missing — callers then fall back to log-only ack.
    public static func parseStreamLifecycle(from body: Data, isLive: Bool) -> TwitchEventSubStreamLifecycle? {
        guard let decoded = try? JSONDecoder().decode(StreamLifecycleWebhookBody.self, from: body),
              let event = decoded.event
        else { return nil }
        let broadcaster = (event.broadcasterUserLogin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !broadcaster.isEmpty else { return nil }
        return TwitchEventSubStreamLifecycle(broadcasterLogin: broadcaster, isLive: isLive)
    }

    public static func logLine(for outcome: Outcome) -> String {
        switch outcome {
        case .challenge:
            return "Twitch EventSub: challenge (route echoes body)"
        case .revocation(let subscriptionType, let status):
            return "Twitch EventSub: revocation type=\(subscriptionType) status=\(status ?? "unknown")"
        case .notificationChatIngest(let chat):
            return "Twitch EventSub: \(chatMessageSubscriptionType) from \(chat.chatterLogin) in #\(chat.broadcasterLogin) — ingesting"
        case .notificationStreamOnline(let lifecycle):
            return "Twitch EventSub: \(streamOnlineSubscriptionType) #\(lifecycle.broadcasterLogin) — stream live"
        case .notificationStreamOffline(let lifecycle):
            return "Twitch EventSub: \(streamOfflineSubscriptionType) #\(lifecycle.broadcasterLogin) — stream offline"
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

private struct StreamLifecycleWebhookBody: Decodable {
    struct Event: Decodable {
        var broadcasterUserLogin: String?

        enum CodingKeys: String, CodingKey {
            case broadcasterUserLogin = "broadcaster_user_login"
        }
    }

    var event: Event?
}
