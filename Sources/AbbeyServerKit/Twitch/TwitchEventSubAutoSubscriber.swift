import AbbeyCore
import Vapor

/// Env-gated EventSub auto-subscribe at server boot.
///
/// Off by default. When `ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE=1` and the full env contract is
/// present, boot fetches an app access token and creates webhook subscriptions for chat,
/// stream lifecycle, follow, subscribe, and cheer events via `TwitchHelixClient`. Missing or
/// invalid configuration skips the whole flow. A failure for one subscription is logged and
/// does not prevent later event types from being attempted. Boot never crashes. Claim-honest:
/// this flow is unverified against Twitch's live API; the `webhook_callback_verification`
/// handshake needs a publicly reachable HTTPS callback this environment can't provide.
public enum TwitchEventSubAutoSubscriber {
    public struct SubscriptionSpec: Equatable, Sendable {
        public let type: String
        public let version: String
        /// Additional Twitch condition key populated with `TWITCH_BOT_USER_ID`.
        /// Chat uses `user_id`; follow v2 uses `moderator_user_id`.
        public let botUserConditionKey: String?

        public init(type: String, version: String, botUserConditionKey: String? = nil) {
            self.type = type
            self.version = version
            self.botUserConditionKey = botUserConditionKey
        }

        public func condition(broadcasterUserId: String, botUserId: String) -> [String: String] {
            var condition = ["broadcaster_user_id": broadcasterUserId]
            if let botUserConditionKey {
                condition[botUserConditionKey] = botUserId
            }
            return condition
        }
    }

    /// Twitch's EventSub wire contract varies by event type. In particular, `channel.follow`
    /// is version 2 and requires the moderator user id; subscribe and cheer remain version 1
    /// with a broadcaster-only condition.
    public static let subscriptionSpecs: [SubscriptionSpec] = [
        .init(type: TwitchEventSubHandler.chatMessageSubscriptionType, version: "1", botUserConditionKey: "user_id"),
        .init(type: TwitchEventSubHandler.streamOnlineSubscriptionType, version: "1"),
        .init(type: TwitchEventSubHandler.streamOfflineSubscriptionType, version: "1"),
        .init(type: TwitchEventSubHandler.followSubscriptionType, version: "2", botUserConditionKey: "moderator_user_id"),
        .init(type: TwitchEventSubHandler.subscribeSubscriptionType, version: "1"),
        .init(type: TwitchEventSubHandler.cheerSubscriptionType, version: "1"),
    ]

    /// Kept for callers that still reference the chat-only constant.
    public static let subscriptionType = TwitchEventSubHandler.chatMessageSubscriptionType

    public struct Config: Equatable, Sendable {
        public let clientId: String
        public let clientSecret: String
        public let callbackURL: String
        public let webhookSecret: String
        public let broadcasterUserId: String
        public let botUserId: String

        public init(
            clientId: String,
            clientSecret: String,
            callbackURL: String,
            webhookSecret: String,
            broadcasterUserId: String,
            botUserId: String
        ) {
            self.clientId = clientId
            self.clientSecret = clientSecret
            self.callbackURL = callbackURL
            self.webhookSecret = webhookSecret
            self.broadcasterUserId = broadcasterUserId
            self.botUserId = botUserId
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Flag unset/false — the default; boot does nothing.
        case disabled
        /// Flag set but required env vars are absent (sorted names).
        case missingEnvironment([String])
        /// Callback must be `https://…` — Twitch rejects anything else.
        case invalidCallbackURL(String)
        /// The operator must finish Twitch user authorization for the requested event
        /// scopes before an app-token subscription can be accepted.
        case authorizationNotConfirmed
        case ready(Config)
    }

    public static let requiredAuthorizationScopes: [String] = [
        "user:read:chat",
        "user:bot",
        "moderator:read:followers",
        "channel:read:subscriptions",
        "bits:read",
    ]

    static let requiredEnvironment: [String] = [
        "TWITCH_CLIENT_ID",
        "TWITCH_CLIENT_SECRET",
        "TWITCH_EVENTSUB_SECRET",
        "TWITCH_EVENTSUB_CALLBACK_URL",
        "TWITCH_BROADCASTER_USER_ID",
        "TWITCH_BOT_USER_ID",
        "TWITCH_EVENTSUB_AUTHORIZATION_CONFIRMED"
    ]

    /// Pure decision from an environment snapshot — unit-testable without a server.
    public static func decide(environment: [String: String]) -> Decision {
        let flag = (environment["ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard flag == "1" || flag == "true" else { return .disabled }

        var values: [String: String] = [:]
        var missing: [String] = []
        for name in requiredEnvironment {
            let value = (environment[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                missing.append(name)
            } else {
                values[name] = value
            }
        }
        guard missing.isEmpty else { return .missingEnvironment(missing.sorted()) }

        let authorizationConfirmed = values["TWITCH_EVENTSUB_AUTHORIZATION_CONFIRMED"]!
            .lowercased()
        guard authorizationConfirmed == "1" || authorizationConfirmed == "true" else {
            return .authorizationNotConfirmed
        }

        let callback = values["TWITCH_EVENTSUB_CALLBACK_URL"]!
        guard callback.lowercased().hasPrefix("https://") else {
            return .invalidCallbackURL(callback)
        }

        return .ready(Config(
            clientId: values["TWITCH_CLIENT_ID"]!,
            clientSecret: values["TWITCH_CLIENT_SECRET"]!,
            callbackURL: callback,
            webhookSecret: values["TWITCH_EVENTSUB_SECRET"]!,
            broadcasterUserId: values["TWITCH_BROADCASTER_USER_ID"]!,
            botUserId: values["TWITCH_BOT_USER_ID"]!
        ))
    }

    /// Runs the subscribe flow when configured. Returns whether **all** subscription requests
    /// were accepted by Helix. Never throws; every non-ready path logs and returns false.
    /// Individual subscription failures are isolated so later event types are still attempted.
    @discardableResult
    public static func subscribeIfConfigured(
        app: Application,
        client: (any Client)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Bool {
        switch decide(environment: environment) {
        case .disabled:
            return false
        case .missingEnvironment(let names):
            app.logger.warning(
                "Twitch EventSub auto-subscribe: flag set but missing \(names.joined(separator: ", ")) — skipping"
            )
            return false
        case .invalidCallbackURL(let url):
            app.logger.warning(
                "Twitch EventSub auto-subscribe: TWITCH_EVENTSUB_CALLBACK_URL must be https:// (got \(url)) — skipping"
            )
            return false
        case .authorizationNotConfirmed:
            app.logger.warning(
                "Twitch EventSub auto-subscribe: complete Twitch user authorization for scopes \(requiredAuthorizationScopes.joined(separator: ", ")); for chat, also grant channel:bot from the broadcaster or make the bot a moderator; then set TWITCH_EVENTSUB_AUTHORIZATION_CONFIRMED=1 — skipping"
            )
            return false
        case .ready(let config):
            let helix = TwitchHelixClient(
                client: client ?? app.client,
                clientId: config.clientId,
                clientSecret: config.clientSecret
            )
            let token: String
            do {
                token = try await helix.fetchAppAccessToken()
            } catch {
                app.logger.warning(
                    "Twitch EventSub auto-subscribe token request failed (boot continues): \(OperatorFacingError.message(error))"
                )
                return false
            }

            var allSucceeded = true
            for spec in subscriptionSpecs {
                do {
                    let outcome = try await helix.createSubscription(
                        type: spec.type,
                        version: spec.version,
                        condition: spec.condition(
                            broadcasterUserId: config.broadcasterUserId,
                            botUserId: config.botUserId
                        ),
                        callbackURL: config.callbackURL,
                        webhookSecret: config.webhookSecret,
                        appAccessToken: token
                    )
                    switch outcome {
                    case .created:
                        app.logger.info(
                            "Twitch EventSub auto-subscribe: \(spec.type) subscription requested for broadcaster \(config.broadcasterUserId) → \(config.callbackURL)"
                        )
                    case .alreadyExists:
                        app.logger.info(
                            "Twitch EventSub auto-subscribe: \(spec.type) already exists; reconciled without creating a duplicate"
                        )
                    }
                } catch {
                    allSucceeded = false
                    app.logger.warning(
                        "Twitch EventSub auto-subscribe: \(spec.type) failed; continuing with remaining types: \(OperatorFacingError.message(error))"
                    )
                }
            }
            return allSucceeded
        }
    }
}
