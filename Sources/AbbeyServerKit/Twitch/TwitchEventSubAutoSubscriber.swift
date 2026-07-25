import AbbeyCore
import Vapor

/// Env-gated EventSub auto-subscribe at server boot.
///
/// Off by default. When `ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE=1` and the full env contract is
/// present, boot fetches an app access token and creates webhook subscriptions for the types
/// with product side-effects (`channel.chat.message`, `stream.online`, `stream.offline`) via
/// `TwitchHelixClient`. Any missing/invalid config or Helix failure logs a warning and skips —
/// it never crashes boot. Claim-honest: this flow is unverified against Twitch's live API;
/// the `webhook_callback_verification` handshake needs a publicly reachable HTTPS callback
/// this environment can't provide.
public enum TwitchEventSubAutoSubscriber {
    public static let subscriptionVersion = "1"

    /// Subscriptions created when auto-subscribe is enabled (types with product side-effects).
    public static let subscriptionSpecs: [(type: String, needsBotUserId: Bool)] = [
        (TwitchEventSubHandler.chatMessageSubscriptionType, true),
        (TwitchEventSubHandler.streamOnlineSubscriptionType, false),
        (TwitchEventSubHandler.streamOfflineSubscriptionType, false)
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
        case ready(Config)
    }

    static let requiredEnvironment: [String] = [
        "TWITCH_CLIENT_ID",
        "TWITCH_CLIENT_SECRET",
        "TWITCH_EVENTSUB_SECRET",
        "TWITCH_EVENTSUB_CALLBACK_URL",
        "TWITCH_BROADCASTER_USER_ID",
        "TWITCH_BOT_USER_ID"
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
    /// A mid-list Helix failure warns, skips the remaining types, and returns false — boot continues.
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
        case .ready(let config):
            let helix = TwitchHelixClient(
                client: client ?? app.client,
                clientId: config.clientId,
                clientSecret: config.clientSecret
            )
            do {
                let token = try await helix.fetchAppAccessToken()
                for spec in subscriptionSpecs {
                    var condition = ["broadcaster_user_id": config.broadcasterUserId]
                    if spec.needsBotUserId {
                        condition["user_id"] = config.botUserId
                    }
                    try await helix.createSubscription(
                        type: spec.type,
                        version: subscriptionVersion,
                        condition: condition,
                        callbackURL: config.callbackURL,
                        webhookSecret: config.webhookSecret,
                        appAccessToken: token
                    )
                    app.logger.info(
                        "Twitch EventSub auto-subscribe: \(spec.type) subscription requested for broadcaster \(config.broadcasterUserId) → \(config.callbackURL)"
                    )
                }
                return true
            } catch {
                app.logger.warning(
                    "Twitch EventSub auto-subscribe failed (boot continues): \(OperatorFacingError.message(error))"
                )
                return false
            }
        }
    }
}
