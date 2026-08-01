import AbbeyServerKit
import Fluent
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

enum TwitchEventSubRoutes {
    /// Database-backed dedupe of EventSub message ids — survives restarts and is shared by
    /// every instance pointed at the same database. Holds no state itself.
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
                guard AbbeyAPIAuth.allowsExplicitWebhookBypass(
                    req,
                    switchName: "ABBEY_ALLOW_UNSIGNED_TWITCH_EVENTSUB_FOR_TESTING"
                ) else {
                    req.logger.error(
                        "Twitch EventSub webhook rejected: TWITCH_EVENTSUB_SECRET is not configured"
                    )
                    throw Abort(
                        .serviceUnavailable,
                        reason: "TWITCH_EVENTSUB_SECRET must be configured before enabling EventSub"
                    )
                }
                req.logger.warning(
                    "Twitch EventSub signature bypass active for dry-run/testing"
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

            if let messageId {
                // Fail closed: if the claim itself cannot be recorded we must not process,
                // or the restart-safety this guard exists for is lost. Twitch retries on 503.
                let claimed: Bool
                do {
                    claimed = try await replayGuard.claim(messageId, on: req.db)
                } catch {
                    req.logger.error("Twitch EventSub replay claim failed; asking Twitch to retry: \(error)")
                    throw Abort(
                        .serviceUnavailable,
                        reason: "Twitch EventSub dedupe unavailable; retry the delivery"
                    )
                }
                if !claimed {
                    req.logger.info(
                        "Twitch EventSub webhook: duplicate messageId=\(messageId); acking without reprocessing"
                    )
                    return try await WebhookAckDTO.duplicate.encodeResponse(for: req)
                }
            }

            let messageType = req.headers.first(name: "Twitch-Eventsub-Message-Type") ?? "unknown"
            let outcome = TwitchEventSubHandler.handle(
                messageType: messageType,
                subscriptionType: body.subscription?.type,
                subscriptionStatus: body.subscription?.status,
                body: rawBody
            )
            req.logger.info("\(TwitchEventSubHandler.logLine(for: outcome))")

            let ack: WebhookAckDTO
            do {
                ack = try await apply(outcome, deliveryId: messageId, on: req)
            } catch {
                // The claim is released here and only here, so it stays adjacent to the single
                // call that can fail — Twitch is then free to retry this delivery id. A failed
                // release must not mask the 503 below; worst case the id stays claimed until
                // it ages out of the replay window.
                if let messageId {
                    do {
                        try await replayGuard.release(messageId, on: req.db)
                    } catch let releaseError {
                        req.logger.error(
                            "Twitch EventSub replay release failed for messageId=\(messageId): \(releaseError)"
                        )
                    }
                }
                req.logger.error("Twitch EventSub processing failed; delivery released for retry: \(error)")
                throw Abort(
                    .serviceUnavailable,
                    reason: "Twitch EventSub processing failed; retry the delivery"
                )
            }

            return try await ack.encodeResponse(for: req)
        }
    }

    /// Dispatch one classified EventSub outcome to the runtime and describe what happened.
    /// Throwing means "we did not durably record this" — the caller turns that into a retryable
    /// response; every non-throwing path has already committed whatever it claims in the ack.
    private static func apply(
        _ outcome: TwitchEventSubHandler.Outcome,
        deliveryId: String?,
        on req: Request
    ) async throws -> WebhookAckDTO {
        let runtime = req.application.botRuntime
        switch outcome {
        case .challenge:
            return .handled("challenge")
        case .revocation:
            return .handled("revocation")
        case .notificationChatIngest(let chat):
            let ingest = await runtime.handleTwitchChat(
                login: chat.chatterLogin,
                channel: chat.broadcasterLogin,
                text: chat.text,
                deliveryId: deliveryId
            )
            // nil = the bot's own echo: accepted, deliberately not ingested, not a replay.
            guard let ingest else { return .acknowledged("self-message") }
            return try .forIngest(ingest, inserted: "notification-ingested")
        case .notificationStreamOnline(let lifecycle):
            await runtime.handleTwitchStreamLifecycle(
                broadcasterLogin: lifecycle.broadcasterLogin,
                isLive: true
            )
            return .handled("stream-online")
        case .notificationStreamOffline(let lifecycle):
            await runtime.handleTwitchStreamLifecycle(
                broadcasterLogin: lifecycle.broadcasterLogin,
                isLive: false
            )
            return .handled("stream-offline")
        case .notificationChannelSocial(let event):
            try await runtime.handleTwitchChannelSocial(
                kind: event.kind,
                broadcasterLogin: event.broadcasterLogin,
                actorLogin: event.actorLogin,
                detail: event.detail,
                deliveryId: deliveryId
            )
            return .handled("channel-social")
        case .notificationAcknowledged:
            return .acknowledged("notification")
        case .ignored:
            return .acknowledged("ignored")
        }
    }
}
