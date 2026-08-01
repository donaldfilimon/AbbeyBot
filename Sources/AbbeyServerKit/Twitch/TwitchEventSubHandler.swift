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
/// - `channel.follow` / `channel.subscribe` / `channel.cheer` →
///   `BotRuntime.handleTwitchChannelSocial`
/// Other notification types stay typed-ack + log-only.
public enum TwitchEventSubHandler {
    public static let chatMessageSubscriptionType = "channel.chat.message"
    public static let streamOnlineSubscriptionType = "stream.online"
    public static let streamOfflineSubscriptionType = "stream.offline"
    public static let followSubscriptionType = "channel.follow"
    public static let subscribeSubscriptionType = "channel.subscribe"
    public static let cheerSubscriptionType = "channel.cheer"

    public struct ChannelSocialEvent: Equatable, Sendable {
        public let kind: String
        public let broadcasterLogin: String
        public let actorLogin: String
        public let detail: String

        public init(kind: String, broadcasterLogin: String, actorLogin: String, detail: String) {
            self.kind = kind
            self.broadcasterLogin = broadcasterLogin
            self.actorLogin = actorLogin
            self.detail = detail
        }
    }

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
        /// follow / subscribe / cheer — log interaction + optional status note.
        case notificationChannelSocial(event: ChannelSocialEvent)
        /// Any other notification type we acknowledge and log (no product side-effect).
        case notificationAcknowledged(subscriptionType: String)
        /// Message type we don't model (still ack 2xx so Twitch stops retrying).
        case ignored(messageType: String, subscriptionType: String)
    }

    /// Classify a delivery. `messageType` is `Twitch-Eventsub-Message-Type`; `body` is the raw
    /// webhook JSON (used to parse chat, stream-lifecycle, and channel-social payloads).
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
            if sub == followSubscriptionType || sub == subscribeSubscriptionType || sub == cheerSubscriptionType,
               let body,
               let social = parseChannelSocial(from: body, kind: sub)
            {
                return .notificationChannelSocial(event: social)
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
        case .notificationChannelSocial(let event):
            return "Twitch EventSub: \(event.kind) #\(event.broadcasterLogin) by \(event.actorLogin) — \(event.detail)"
        case .notificationAcknowledged(let subscriptionType):
            return "Twitch EventSub: notification type=\(subscriptionType) acknowledged (no product side-effect)"
        case .ignored(let messageType, let subscriptionType):
            return "Twitch EventSub: ignored messageType=\(messageType) subscriptionType=\(subscriptionType)"
        }
    }

    /// Parse follow, subscribe, and cheer payloads into the shared social-event shape.
    /// Anonymous cheers legitimately omit a user login and are represented as `unknown`.
    public static func parseChannelSocial(from body: Data, kind: String) -> ChannelSocialEvent? {
        guard let decoded = try? JSONDecoder().decode(ChannelSocialWebhookBody.self, from: body),
              let event = decoded.event
        else { return nil }
        let broadcaster = (event.broadcasterUserLogin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let actor = (event.userLogin ?? event.chatterUserLogin ?? "unknown")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !broadcaster.isEmpty else { return nil }
        let detail: String
        switch kind {
        case followSubscriptionType:
            detail = "followed"
        case subscribeSubscriptionType:
            detail = "subscribed tier=\(event.tier ?? "?")"
        case cheerSubscriptionType:
            detail = "cheered bits=\(event.bits.map(String.init) ?? "?") \(event.message ?? "")"
        default:
            detail = kind
        }
        return ChannelSocialEvent(
            kind: kind,
            broadcasterLogin: broadcaster,
            actorLogin: actor.isEmpty ? "unknown" : actor,
            detail: detail.trimmingCharacters(in: .whitespacesAndNewlines)
        )
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

private struct ChannelSocialWebhookBody: Decodable {
    struct Event: Decodable {
        var broadcasterUserLogin: String?
        var userLogin: String?
        var chatterUserLogin: String?
        var tier: String?
        var bits: Int?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case broadcasterUserLogin = "broadcaster_user_login"
            case userLogin = "user_login"
            case chatterUserLogin = "chatter_user_login"
            case tier, bits, message
        }
    }

    var event: Event?
}
