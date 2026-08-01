import AbbeyCore
import Fluent
import Foundation
import Vapor

extension BotRuntime {
    /// Shared Twitch chat path: ingest under `guildId=twitch`, then persona reply via IRC with
    /// cooldown. Used by both the IRC PRIVMSG hooks and EventSub `channel.chat.message`
    /// notifications so the two transports cannot drift. Replies go out over the IRC bridge —
    /// when it isn't connected `sendPrivmsg` logs and drops the reply (ingest still happened).
    /// Returns `nil` when the message was never a candidate for ingest (the bot seeing its own
    /// echo) — distinct from `.duplicate`, which means Twitch redelivered a message we already
    /// stored. Callers must not conflate the two: only the latter is a replayed *delivery*.
    @discardableResult
    public func handleTwitchChat(
        login: String,
        channel: String,
        text: String,
        deliveryId: String? = nil
    ) async -> MessageIngestOutcome? {
        let botNick = (await twitchBridge.loginNick ?? "").lowercased()
        if !botNick.isEmpty, login.lowercased() == botNick { return nil }
        let outcome = await ingestMessageOutcome(
            content: text,
            channelId: channel,
            guildId: "twitch",
            authorId: login,
            discordMessageId: Self.twitchIngestKey(
                deliveryId: deliveryId,
                fallback: "twitch-irc-\(UUID().uuidString)"
            )
        )
        guard case .inserted(let strategy) = outcome else { return outcome }
        if await scheduler.isCoolingDown(userId: login, guildId: "twitch") {
            return outcome
        }
        guard let reply = await craftReply(
            content: text,
            channelId: channel,
            guildId: "twitch",
            authorId: login,
            strategy: strategy
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { return outcome }
        await twitchBridge.sendPrivmsg(channel: channel, text: reply)
        await scheduler.markReplied(userId: login, guildId: "twitch")
        return outcome
    }

    /// EventSub `stream.online` / `stream.offline` — updates operator-visible stream-live
    /// state, publishes on the event bus, and logs an interaction. No Discord/IRC announce.
    ///
    /// Deliberately non-throwing: the only durable state here is an idempotent in-memory flag,
    /// so asking Twitch to retry could not recover anything a retry would not already have. It
    /// would only append a second audit row. The audit write is therefore best-effort.
    public func handleTwitchStreamLifecycle(broadcasterLogin: String, isLive: Bool) async {
        twitchStreamLive = isLive
        await eventBus.publish(
            .twitchStreamLifecycle(broadcasterLogin: broadcasterLogin, isLive: isLive)
        )
        let command = isLive ? "eventsub.stream.online" : "eventsub.stream.offline"
        await auditTwitchEvent(commandName: command, userId: broadcasterLogin)
    }

    /// EventSub follow / subscribe / cheer — ingest a soft memory note, then (for a genuinely
    /// new delivery only) publish on the event bus, credit the actor's Twitch reputation, and
    /// audit it. No Discord/IRC announce: this package deliberately does not broadcast these.
    ///
    /// Ingest runs first and carries the dedup key, so a retried delivery collides with the row
    /// the first attempt stored and returns `.duplicate`; every side-effect below hangs off the
    /// `.inserted` branch, so a retry adds no second bus event, no second reputation nudge (the
    /// EMA is *not* idempotent — a repeat would move the score again), and no second audit row.
    /// Only ingest failure throws — it is the one part a retry can actually recover. Reputation
    /// and audit persistence failures are swallowed by design for the same reason: retrying them
    /// would re-run the whole handler and duplicate the parts that did succeed.
    public func handleTwitchChannelSocial(
        kind: String,
        broadcasterLogin: String,
        actorLogin: String,
        detail: String,
        deliveryId: String? = nil
    ) async throws {
        app.logger.info("Twitch \(kind) #\(broadcasterLogin) \(actorLogin): \(detail)")
        let outcome = await ingestMessageOutcome(
            content: "[\(kind)] \(actorLogin): \(detail)",
            channelId: broadcasterLogin,
            guildId: "twitch",
            authorId: "twitch-system",
            discordMessageId: Self.twitchIngestKey(
                deliveryId: deliveryId,
                fallback: "twitch-\(kind)-\(UUID().uuidString)"
            )
        )
        switch outcome {
        case .failed:
            throw BotRuntimeEventProcessingError.ingestFailed
        case .duplicate:
            return
        case .inserted:
            await eventBus.publish(
                .twitchChannelSocial(
                    kind: kind,
                    broadcasterLogin: broadcasterLogin,
                    actorLogin: actorLogin,
                    detail: detail
                )
            )
            await creditTwitchSocialReputation(kind: kind, actorLogin: actorLogin)
            await auditTwitchEvent(commandName: "eventsub.\(kind)", userId: actorLogin)
        }
    }

    /// Nudge the actor's `guildId=twitch` reputation through the shared social brain — the same
    /// EMA path chat ingest uses, not a parallel score. Skipped for the anonymous actor because
    /// `TwitchEventSubHandler.parseChannelSocial` collapses every anonymous cheerer onto one
    /// synthetic login, and pooling them into a single identity's score would be meaningless.
    private func creditTwitchSocialReputation(kind: String, actorLogin: String) async {
        let suffix = Self.twitchSocialKindSuffix(kind)
        guard let quality = Self.twitchSocialReputationQuality(kindSuffix: suffix) else { return }
        let actor = actorLogin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !actor.isEmpty, actor.lowercased() != Self.twitchAnonymousActorLogin else { return }
        await socialBrain.recordInteraction(
            userId: actor,
            guildId: "twitch",
            quality: quality,
            reason: "twitch.\(suffix)"
        )
    }

    /// Login `TwitchEventSubHandler.parseChannelSocial` substitutes when a payload carries no
    /// user — anonymous cheers, principally.
    static let twitchAnonymousActorLogin = "unknown"

    /// Trailing component of an EventSub subscription type, so both the wire form
    /// (`channel.follow`) and the bare form (`follow`) resolve to the same key.
    static func twitchSocialKindSuffix(_ kind: String) -> String {
        String(kind.lowercased().split(separator: ".").last ?? "")
    }

    /// EMA *target* per social kind — not a fixed delta. `recordInteraction` blends the current
    /// score toward this by `1 - reputationDecay`, so a follow moves an average viewer up a
    /// little and a subscription more. `nil` for any other kind: it still gets a bus event and
    /// an audit row, it just doesn't move anyone's score.
    static func twitchSocialReputationQuality(kindSuffix: String) -> Double? {
        switch kindSuffix {
        case "follow": return 0.65
        case "cheer": return 0.80
        case "subscribe": return 0.90
        default: return nil
        }
    }

    /// EventSub deliveries dedupe on Twitch's message id, so a retried delivery collides with
    /// the row the first attempt stored. IRC has no delivery id, so each PRIVMSG gets its own.
    static func twitchIngestKey(deliveryId: String?, fallback: @autoclosure () -> String) -> String {
        deliveryId.map { "twitch-eventsub-\($0)" } ?? fallback()
    }

    /// Best-effort audit row for a platform event. Never throws: the durable record is the
    /// ingested message, and a failed audit must not turn into a retry that duplicates it.
    private func auditTwitchEvent(commandName: String, userId: String) async {
        do {
            try await InteractionRepository.log(
                commandName: commandName,
                userId: userId,
                guildId: "twitch",
                succeeded: true,
                latencyMs: 0,
                on: app.db
            )
        } catch {
            app.logger.warning(
                "Twitch \(commandName) audit log failed: \(OperatorFacingError.message(error))"
            )
        }
    }
}
