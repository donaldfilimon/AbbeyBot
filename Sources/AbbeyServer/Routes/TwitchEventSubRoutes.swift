import Vapor

/// Stub webhook receiver for Twitch EventSub. Handles callback verification (`challenge` echo)
/// and logs notification/revocation payloads. Full subscribe flow and HMAC signature verify
/// (`Twitch-Eventsub-Message-Signature`) are deferred — see AGENTS.md.
struct TwitchEventSubWebhookDTO: Content {
    var challenge: String?
    var subscription: TwitchEventSubSubscriptionDTO?
}

struct TwitchEventSubSubscriptionDTO: Content {
    var id: String?
    var type: String?
    var status: String?
}

struct TwitchEventSubAckDTO: Content {
    var ok: Bool
    var handled: Bool
}

enum TwitchEventSubRoutes {
    static func register(on app: Application) {
        app.post("api", "twitch", "eventsub") { req async throws -> Response in
            let body = try req.content.decode(TwitchEventSubWebhookDTO.self)

            if let challenge = body.challenge?.trimmingCharacters(in: .whitespacesAndNewlines),
               !challenge.isEmpty
            {
                var headers = HTTPHeaders()
                headers.contentType = .plainText
                return Response(status: .ok, headers: headers, body: .init(string: challenge))
            }

            let messageType = req.headers.first(name: "Twitch-Eventsub-Message-Type") ?? "unknown"
            let subscriptionType = body.subscription?.type ?? "unknown"
            req.logger.info(
                "Twitch EventSub webhook stub: messageType=\(messageType) subscriptionType=\(subscriptionType); signature verify deferred, not handled"
            )

            return try await TwitchEventSubAckDTO(ok: true, handled: false).encodeResponse(for: req)
        }
    }
}
