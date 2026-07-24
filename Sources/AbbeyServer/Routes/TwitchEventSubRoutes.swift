import AbbeyServerKit
import Foundation
import Vapor

/// Webhook receiver for Twitch EventSub. Verifies the HMAC-SHA256 signature Twitch attaches
/// to every delivery (`Twitch-Eventsub-Message-Signature`), then handles callback verification
/// (`challenge` echo) and logs notification/revocation payloads. See AGENTS.md for what's
/// still deferred (message-id replay dedup, per-event-type business logic).
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
            guard let bodyBuffer = req.body.data else {
                throw Abort(.badRequest, reason: "Missing request body")
            }
            let rawBody = Data(bodyBuffer.readableBytesView)

            if let secret = Environment.get("TWITCH_EVENTSUB_SECRET"), !secret.isEmpty {
                let messageId = req.headers.first(name: "Twitch-Eventsub-Message-Id")
                let timestamp = req.headers.first(name: "Twitch-Eventsub-Message-Timestamp")
                let signature = req.headers.first(name: "Twitch-Eventsub-Message-Signature")

                guard let messageId, let timestamp,
                      TwitchEventSubSignature.isWithinReplayWindow(timestamp: timestamp, now: Date()),
                      TwitchEventSubSignature.verify(
                          messageId: messageId,
                          timestamp: timestamp,
                          body: rawBody,
                          signatureHeader: signature,
                          secret: secret
                      )
                else {
                    req.logger.warning("Twitch EventSub webhook: signature verification failed, rejecting")
                    throw Abort(.forbidden, reason: "Invalid Twitch EventSub signature")
                }
            } else {
                req.logger.warning(
                    "Twitch EventSub webhook: TWITCH_EVENTSUB_SECRET not configured, skipping signature verification"
                )
            }

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
                "Twitch EventSub webhook: messageType=\(messageType) subscriptionType=\(subscriptionType) verified=ok; per-event handling deferred"
            )

            return try await TwitchEventSubAckDTO(ok: true, handled: false).encodeResponse(for: req)
        }
    }
}
