import AbbeyServerKit
import Foundation
import Vapor

/// Webhook receiver for Twitch EventSub. Verifies the HMAC-SHA256 signature Twitch attaches
/// to every delivery (`Twitch-Eventsub-Message-Signature`), then handles callback verification
/// (`challenge` echo), dedupes by `Twitch-Eventsub-Message-Id`, and dispatches per message type
/// via `TwitchEventSubHandler`. `channel.chat.message` feeds `BotRuntime.handleTwitchChat`;
/// `stream.online` / `stream.offline` feed `handleTwitchStreamLifecycle`. Other notification
/// types stay log-only. Still deferred: PubSub (Twitch-deprecated) and the live Helix
/// handshake (needs a public HTTPS callback).
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
    var outcome: String?
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
                return try await TwitchEventSubAckDTO(
                    ok: true, handled: false, duplicate: true, outcome: "duplicate"
                ).encodeResponse(for: req)
            }

            let messageType = req.headers.first(name: "Twitch-Eventsub-Message-Type") ?? "unknown"
            let outcome = TwitchEventSubHandler.handle(
                messageType: messageType,
                subscriptionType: body.subscription?.type,
                subscriptionStatus: body.subscription?.status,
                body: rawBody
            )
            req.logger.info("\(TwitchEventSubHandler.logLine(for: outcome))")

            let handled: Bool
            let outcomeLabel: String
            switch outcome {
            case .challenge:
                handled = true
                outcomeLabel = "challenge"
            case .revocation:
                handled = true
                outcomeLabel = "revocation"
            case .notificationChatIngest(let chat):
                await req.application.botRuntime.handleTwitchChat(
                    login: chat.chatterLogin,
                    channel: chat.broadcasterLogin,
                    text: chat.text
                )
                handled = true
                outcomeLabel = "notification-ingested"
            case .notificationStreamOnline(let lifecycle):
                await req.application.botRuntime.handleTwitchStreamLifecycle(
                    broadcasterLogin: lifecycle.broadcasterLogin,
                    isLive: true
                )
                handled = true
                outcomeLabel = "stream-online"
            case .notificationStreamOffline(let lifecycle):
                await req.application.botRuntime.handleTwitchStreamLifecycle(
                    broadcasterLogin: lifecycle.broadcasterLogin,
                    isLive: false
                )
                handled = true
                outcomeLabel = "stream-offline"
            case .notificationAcknowledged:
                handled = false
                outcomeLabel = "notification"
            case .ignored:
                handled = false
                outcomeLabel = "ignored"
            }

            return try await TwitchEventSubAckDTO(
                ok: true, handled: handled, duplicate: false, outcome: outcomeLabel
            ).encodeResponse(for: req)
        }
    }
}
