import AbbeyCore
import AbbeyServerKit
import Fluent
import Foundation
import Testing
import Vapor

/// Follow / subscribe / cheer used to be log-only. They now publish on the event bus and move
/// the actor's `guildId=twitch` reputation — both of which must stay strictly on the "this
/// delivery actually inserted" branch, because Twitch retries any delivery it thinks failed.
@Suite("Twitch channel social side-effects", .serialized)
struct TwitchChannelSocialEffectsTests {
    // MARK: - Harness

    private func withRuntime<T: Sendable>(
        _ body: @Sendable (Application, BotRuntime) async throws -> T
    ) async throws -> T {
        unsetenv("DISCORD_BOT_TOKEN")
        unsetenv("DISCORD_DEV_GUILD_ID")

        let app = try await Application.make(.testing)
        // Application.make loads `.env` into the process environment — force an in-memory
        // URL afterward so configureRuntime cannot pick up a developer Postgres/sqlite file.
        setenv("DATABASE_URL", "sqlite://memory", 1)
        do {
            let runtime = try await configureRuntime(app, defaultDatabaseURL: "sqlite://memory")
            let result = try await body(app, runtime)
            try await app.asyncShutdown()
            return result
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    struct SocialEvent: Sendable, Equatable {
        var kind: String
        var broadcasterLogin: String
        var actorLogin: String
        var detail: String
    }

    /// Drains an `EventBus` subscription into an actor so tests can count what was published
    /// without racing the publisher.
    private actor EventCollector {
        private var events: [AbbeyEvent] = []

        func append(_ event: AbbeyEvent) { events.append(event) }

        func socialEvents() -> [SocialEvent] {
            var found: [SocialEvent] = []
            for event in events {
                guard case .twitchChannelSocial(let kind, let broadcaster, let actor, let detail) = event
                else { continue }
                found.append(
                    SocialEvent(
                        kind: kind,
                        broadcasterLogin: broadcaster,
                        actorLogin: actor,
                        detail: detail
                    )
                )
            }
            return found
        }

        func reputationReasons() -> [String] {
            events.compactMap { event in
                guard case .reputationChanged(_, _, _, let reason) = event else { return nil }
                return reason
            }
        }
    }

    /// Subscribes, runs `body`, then waits until at least `expectedSocialEvents` social events
    /// have landed. Callers use a trailing delivery with a *fresh* id as a barrier: the stream is
    /// FIFO, so once the barrier's event arrives, anything an earlier delivery would have
    /// published is already enqueued — which turns "no extra event was published" into a
    /// deterministic assertion instead of a sleep.
    private func collectingEvents<T: Sendable>(
        on runtime: BotRuntime,
        expectedSocialEvents: Int,
        _ body: @Sendable (EventCollector) async throws -> T
    ) async throws -> (value: T, collector: EventCollector) {
        let collector = EventCollector()
        let stream = await runtime.eventBus.subscribe()
        let pump = Task {
            for await event in stream { await collector.append(event) }
        }
        defer { pump.cancel() }

        let value = try await body(collector)

        for _ in 0..<400 {
            if await collector.socialEvents().count >= expectedSocialEvents { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return (value, collector)
    }

    private func reputationEventCount(
        reason: String,
        on db: any Database
    ) async throws -> Int {
        try await ReputationEvent.query(on: db).all().filter { $0.reason == reason }.count
    }

    private func interactionCount(
        commandName: String,
        on db: any Database
    ) async throws -> Int {
        try await InteractionLog.query(on: db).all().filter { $0.commandName == commandName }.count
    }

    // MARK: - Tests

    /// A brand-new follow publishes exactly one `twitchChannelSocial` event carrying the payload
    /// verbatim, and raises the follower's Twitch reputation above the default via the shared
    /// social brain (which also persists a `ReputationEvent` tagged with the kind).
    @Test func newFollowPublishesBusEventAndRaisesActorReputation() async throws {
        try await withRuntime { app, runtime in
            let (_, collector) = try await collectingEvents(on: runtime, expectedSocialEvents: 1) { _ in
                try await runtime.handleTwitchChannelSocial(
                    kind: "channel.follow",
                    broadcasterLogin: "somechannel",
                    actorLogin: "someviewer",
                    detail: "followed",
                    deliveryId: "follow-1"
                )
            }

            let social = await collector.socialEvents()
            #expect(social == [
                SocialEvent(
                    kind: "channel.follow",
                    broadcasterLogin: "somechannel",
                    actorLogin: "someviewer",
                    detail: "followed"
                )
            ])

            let state = await runtime.userState(userId: "someviewer", guildId: "twitch")
            #expect(state.reputation > ReputationMath.defaultScore)

            #expect(try await reputationEventCount(reason: "twitch.follow", on: app.db) == 1)
            #expect(try await interactionCount(commandName: "eventsub.channel.follow", on: app.db) == 1)
            #expect(await collector.reputationReasons().contains("twitch.follow"))
        }
    }

    /// Each kind blends toward a different EMA target, so from a common starting score the
    /// ordering subscribe > cheer > follow > default must hold. Asserts the ranking rather than
    /// literal values so a change to `ABBEY_REPUTATION_DECAY` cannot make this flaky.
    @Test func subscribeOutranksCheerOutranksFollow() async throws {
        try await withRuntime { _, runtime in
            try await runtime.handleTwitchChannelSocial(
                kind: "channel.follow", broadcasterLogin: "somechannel",
                actorLogin: "follower", detail: "followed", deliveryId: "d-follow"
            )
            try await runtime.handleTwitchChannelSocial(
                kind: "channel.cheer", broadcasterLogin: "somechannel",
                actorLogin: "cheerer", detail: "cheered bits=100", deliveryId: "d-cheer"
            )
            try await runtime.handleTwitchChannelSocial(
                kind: "channel.subscribe", broadcasterLogin: "somechannel",
                actorLogin: "subscriber", detail: "subscribed tier=1000", deliveryId: "d-sub"
            )

            let follow = await runtime.userState(userId: "follower", guildId: "twitch").reputation
            let cheer = await runtime.userState(userId: "cheerer", guildId: "twitch").reputation
            let subscribe = await runtime.userState(userId: "subscriber", guildId: "twitch").reputation

            #expect(follow > ReputationMath.defaultScore)
            #expect(cheer > follow)
            #expect(subscribe > cheer)
        }
    }

    /// The core regression guard. A redelivered webhook (same `Twitch-Eventsub-Message-Id`)
    /// returns `.duplicate` from ingest, and every side-effect hangs off `.inserted` — so the
    /// retry must add no message row, no audit row, no reputation event, no bus event, and must
    /// leave the score itself byte-identical. The score check is the sharp one: the EMA is not
    /// idempotent, so a second `recordInteraction` at the same quality would visibly move it.
    @Test func retriedDeliveryProducesNoAdditionalSideEffects() async throws {
        try await withRuntime { app, runtime in
            let (reputationAfterFirst, collector) = try await collectingEvents(
                on: runtime,
                // 1 from the original delivery + 1 from the barrier delivery; the retry in
                // between must contribute nothing.
                expectedSocialEvents: 2
            ) { _ in
                try await runtime.handleTwitchChannelSocial(
                    kind: "channel.subscribe",
                    broadcasterLogin: "somechannel",
                    actorLogin: "someviewer",
                    detail: "subscribed tier=1000",
                    deliveryId: "delivery-retry"
                )
                let afterFirst = await runtime.userState(userId: "someviewer", guildId: "twitch").reputation

                // Same delivery id — Twitch redelivering after a 5xx.
                try await runtime.handleTwitchChannelSocial(
                    kind: "channel.subscribe",
                    broadcasterLogin: "somechannel",
                    actorLogin: "someviewer",
                    detail: "subscribed tier=1000",
                    deliveryId: "delivery-retry"
                )

                // Durable state is settled the moment the call returns, so assert before the
                // barrier delivery below adds rows of its own.
                let afterRetry = await runtime.userState(userId: "someviewer", guildId: "twitch").reputation
                #expect(afterRetry == afterFirst)
                #expect(try await reputationEventCount(reason: "twitch.subscribe", on: app.db) == 1)
                #expect(try await interactionCount(commandName: "eventsub.channel.subscribe", on: app.db) == 1)
                let notes = try await MessageRepository.recent(limit: 10, on: app.db)
                    .filter { $0.authorId == "twitch-system" }
                #expect(notes.count == 1)

                // Barrier: a fresh delivery id, so its event is genuinely new. Once it shows up
                // on the stream, the retry has demonstrably published nothing.
                try await runtime.handleTwitchChannelSocial(
                    kind: "channel.subscribe",
                    broadcasterLogin: "somechannel",
                    actorLogin: "otherviewer",
                    detail: "subscribed tier=1000",
                    deliveryId: "delivery-barrier"
                )
                return afterFirst
            }

            let social = await collector.socialEvents()
            #expect(social.count == 2)
            #expect(social.map(\.actorLogin) == ["someviewer", "otherviewer"])
            #expect(reputationAfterFirst > ReputationMath.defaultScore)
        }
    }

    /// Anonymous cheers arrive with the synthetic `unknown` login (see
    /// `TwitchEventSubHandler.parseChannelSocial`). Pooling every anonymous cheerer into one
    /// identity's score would be meaningless, so reputation is skipped — but the bus event and
    /// the audit row still fire, because the event genuinely happened.
    @Test func anonymousCheerSkipsReputationButStillPublishesAndAudits() async throws {
        try await withRuntime { app, runtime in
            let (_, collector) = try await collectingEvents(on: runtime, expectedSocialEvents: 1) { _ in
                try await runtime.handleTwitchChannelSocial(
                    kind: "channel.cheer",
                    broadcasterLogin: "somechannel",
                    actorLogin: "unknown",
                    detail: "cheered bits=100",
                    deliveryId: "cheer-anon"
                )
            }

            #expect(await collector.socialEvents().count == 1)
            #expect(try await interactionCount(commandName: "eventsub.channel.cheer", on: app.db) == 1)

            let state = await runtime.userState(userId: "unknown", guildId: "twitch")
            #expect(state.reputation == ReputationMath.defaultScore)
            #expect(try await reputationEventCount(reason: "twitch.cheer", on: app.db) == 0)
        }
    }

    /// An unrecognised subscription type still logs and publishes, but must not invent a
    /// reputation rule for itself.
    @Test func unrecognisedKindPublishesAndAuditsWithoutReputation() async throws {
        try await withRuntime { app, runtime in
            let (_, collector) = try await collectingEvents(on: runtime, expectedSocialEvents: 1) { _ in
                try await runtime.handleTwitchChannelSocial(
                    kind: "channel.raid",
                    broadcasterLogin: "somechannel",
                    actorLogin: "raider",
                    detail: "raided",
                    deliveryId: "raid-1"
                )
            }

            #expect(await collector.socialEvents().count == 1)
            #expect(try await interactionCount(commandName: "eventsub.channel.raid", on: app.db) == 1)

            let state = await runtime.userState(userId: "raider", guildId: "twitch")
            #expect(state.reputation == ReputationMath.defaultScore)
            #expect(try await reputationEventCount(reason: "twitch.raid", on: app.db) == 0)
        }
    }
}
