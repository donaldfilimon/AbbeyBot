import AbbeyServerKit
import Foundation
import Vapor

/// Webhook receiver for Twitch EventSub. Verifies the HMAC-SHA256 signature Twitch attaches
/// to every delivery (`Twitch-Eventsub-Message-Signature`), then handles callback verification
/// (`challenge` echo), dedupes by `Twitch-Eventsub-Message-Id`, and logs notification/revocation
/// payloads. See AGENTS.md for what's still deferred (per-event-type business logic,
/// auto-subscribe, PubSub).
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
    var duplicate: Bool?
}

enum TwitchEventSubRoutes {
    /// Process-lifetime dedupe of EventSub message ids (not shared across instances).
    static let replayGuard = TwitchEventSubReplayGuard()

    static func register(on app: Application) {
        app.post("api", "twitch", "eventsub") { req async throws -> Response in
            guard let bodyBuffer = req.body.data else {
                throw Abort(.badRequest, reason: "Missing request body")
            }
            let rawBody = Data(bodyBuffer.readableBytesView)
            let messageId = req.headers.first(name: "Twitch-Eventsub-Message-Id")

            if let secret = Environment.get("TWITCH_EVENTSUB_SECRET"), !secret.isEmpty {
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

            // Challenge retries must still echo the challenge — do not consume the message id.
            if let challenge = body.challenge?.trimmingCharacters(in: .whitespacesAndNewlines),
               !challenge.isEmpty
            {
                var headers = HTTPHeaders()
                headers.contentType = .plainText
                return Response(status: .ok, headers: headers, body: .init(string: challenge))
            }

            if let messageId, !replayGuard.claim(messageId) {
                req.logger.info(
                    "Twitch EventSub webhook: duplicate messageId=\(messageId); acking without reprocessing"
                )
                return try await TwitchEventSubAckDTO(ok: true, handled: false, duplicate: true)
                    .encodeResponse(for: req)
            }

            let messageType = req.headers.first(name: "Twitch-Eventsub-Message-Type") ?? "unknown"
            let subscriptionType = body.subscription?.type ?? "unknown"
            req.logger.info(
                "Twitch EventSub webhook: messageType=\(messageType) subscriptionType=\(subscriptionType) verified=ok; per-event handling deferred"
            )

            return try await TwitchEventSubAckDTO(ok: true, handled: false, duplicate: false)
                .encodeResponse(for: req)
        }
    }
}
