import DiscordBM
import Foundation
import Testing
@testable import AbbeyCore

@Suite("Delayed reaction rewards")
struct DelayedRewardLedgerTests {
    private static let state: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func boundLedger(
        author: String = "u1",
        action: Int = 2,
        capacity: Int = 8,
        timeToLive: TimeInterval = 60
    ) async -> DelayedRewardLedger {
        let ledger = DelayedRewardLedger(capacity: capacity, timeToLive: timeToLive)
        await ledger.stage(sourceMessageId: "m1", authorId: author, state: Self.state, action: action, now: Self.t0)
        let bound = await ledger.bind(sourceMessageId: "m1", replyMessageId: "r1", now: Self.t0)
        #expect(bound)
        return ledger
    }

    @Test func emojiTable() {
        #expect(ReactionReward.value(emojiName: "👍", isCustom: false) == 1)
        #expect(ReactionReward.value(emojiName: "❤️", isCustom: false) == 1)
        #expect(ReactionReward.value(emojiName: "👎", isCustom: false) == -1)
        #expect(ReactionReward.value(emojiName: "🦆", isCustom: false) == nil)
        #expect(ReactionReward.value(emojiName: "👍", isCustom: true) == nil)
        #expect(ReactionReward.value(emojiName: nil, isCustom: false) == nil)
    }

    @Test func authorReactionOnReplyYieldsTerminalSampleOnce() async {
        let ledger = await boundLedger()
        let experience = await ledger.reward(
            replyMessageId: "r1", reactorId: "u1", botUserId: "bot",
            emojiName: "👎", isCustomEmoji: false, now: Self.t0.addingTimeInterval(5)
        )
        #expect(experience?.state == Self.state)
        #expect(experience?.action == 2)
        #expect(experience?.reward == -1)
        #expect(experience?.done == true)
        #expect(experience?.nextState == Self.state)

        let again = await ledger.reward(
            replyMessageId: "r1", reactorId: "u1", botUserId: "bot",
            emojiName: "👍", isCustomEmoji: false, now: Self.t0.addingTimeInterval(6)
        )
        #expect(again == nil)
        #expect(await ledger.boundCount == 0)
    }

    @Test func unknownReplyOtherUserAndBotAreIgnored() async {
        let ledger = await boundLedger()
        #expect(await ledger.reward(replyMessageId: "r-other", reactorId: "u1", botUserId: "bot",
                                    emojiName: "👍", isCustomEmoji: false, now: Self.t0) == nil)
        #expect(await ledger.reward(replyMessageId: "r1", reactorId: "u2", botUserId: "bot",
                                    emojiName: "👍", isCustomEmoji: false, now: Self.t0) == nil)
        #expect(await ledger.reward(replyMessageId: "r1", reactorId: "bot", botUserId: "bot",
                                    emojiName: "👍", isCustomEmoji: false, now: Self.t0) == nil)
        #expect(await ledger.boundCount == 1)
    }

    @Test func neutralEmojiKeepsEntryForALaterSignal() async {
        let ledger = await boundLedger()
        #expect(await ledger.reward(replyMessageId: "r1", reactorId: "u1", botUserId: nil,
                                    emojiName: "🦆", isCustomEmoji: false, now: Self.t0) == nil)
        #expect(await ledger.reward(replyMessageId: "r1", reactorId: "u1", botUserId: nil,
                                    emojiName: "👍", isCustomEmoji: false, now: Self.t0)?.reward == 1)
    }

    @Test func expiredEntriesAreDropped() async {
        let ledger = await boundLedger(timeToLive: 60)
        #expect(await ledger.reward(replyMessageId: "r1", reactorId: "u1", botUserId: nil,
                                    emojiName: "👍", isCustomEmoji: false,
                                    now: Self.t0.addingTimeInterval(61)) == nil)
        #expect(await ledger.boundCount == 0)

        let staleStage = DelayedRewardLedger(timeToLive: 60)
        await staleStage.stage(sourceMessageId: "m1", authorId: "u1", state: Self.state, action: 0, now: Self.t0)
        #expect(await staleStage.bind(sourceMessageId: "m1", replyMessageId: "r1",
                                      now: Self.t0.addingTimeInterval(61)) == false)
    }

    @Test func bindWithoutStageFailsAndCapacityEvictsOldest() async {
        let ledger = DelayedRewardLedger(capacity: 2, timeToLive: 600)
        #expect(await ledger.bind(sourceMessageId: "missing", replyMessageId: "r") == false)
        for index in 0..<3 {
            await ledger.stage(sourceMessageId: "m\(index)", authorId: "u", state: Self.state, action: 0,
                               now: Self.t0.addingTimeInterval(Double(index)))
        }
        #expect(await ledger.stagedCount == 2)
        #expect(await ledger.bind(sourceMessageId: "m0", replyMessageId: "r0", now: Self.t0) == false)
        #expect(await ledger.bind(sourceMessageId: "m2", replyMessageId: "r2", now: Self.t0) == true)
    }

    @Test func switchParsingIsDefaultOn() {
        for off in ["0", "false", "NO", " off "] {
            #expect(AppConfig.parseDefaultOnSwitch(off) == false)
        }
        for on in ["1", "true", "yes", "", "maybe"] {
            #expect(AppConfig.parseDefaultOnSwitch(on) == true)
        }
    }

    @Test func appConfigReadsDelayedRewardsSwitch() {
        func config(_ environment: [String: String]) -> AppConfig {
            let suite = "DelayedRewardLedgerTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return AppConfig(defaults: defaults, environment: environment, tokens: InMemoryTokenStore())
        }
        #expect(config([:]).delayedRewardsEnabled == true)
        #expect(config(["ABBEY_DELAYED_REWARDS": "0"]).delayedRewardsEnabled == false)
        #expect(config(["ABBEY_DELAYED_REWARDS": "on"]).delayedRewardsEnabled == true)
    }

    @Test func disabledLedgerStagesNothing() async {
        let ledger = DelayedRewardLedger(isEnabled: false)
        await ledger.stage(sourceMessageId: "m1", authorId: "u1", state: Self.state, action: 0, now: Self.t0)
        #expect(await ledger.stagedCount == 0)
        #expect(await ledger.bind(sourceMessageId: "m1", replyMessageId: "r1", now: Self.t0) == false)
        #expect(await ledger.reward(replyMessageId: "r1", reactorId: "u1", botUserId: nil,
                                    emojiName: "👍", isCustomEmoji: false, now: Self.t0) == nil)
    }

    // MARK: - Deleted replies

    @Test func deletedReplyYieldsPenaltyOnceAndExcludesReactions() async {
        let ledger = await boundLedger()
        let deleted = await ledger.consumeReplyDeletion(replyMessageId: "r1", now: Self.t0)
        #expect(deleted?.reward == ModerationReward.replyDeleted)
        #expect(deleted?.action == 2)
        #expect(await ledger.consumeReplyDeletion(replyMessageId: "r1", now: Self.t0) == nil)
        #expect(await ledger.reward(replyMessageId: "r1", reactorId: "u1", botUserId: nil,
                                    emojiName: "👍", isCustomEmoji: false, now: Self.t0) == nil)
        #expect(await ledger.consumeReplyDeletion(replyMessageId: "unknown", now: Self.t0) == nil)

        let reacted = await boundLedger()
        #expect(await reacted.reward(replyMessageId: "r1", reactorId: "u1", botUserId: nil,
                                     emojiName: "👍", isCustomEmoji: false, now: Self.t0) != nil)
        #expect(await reacted.consumeReplyDeletion(replyMessageId: "r1", now: Self.t0) == nil)
    }

    @Test func gatewayDeletesTrainTheAgent() async throws {
        let ledger = DelayedRewardLedger(timeToLive: .greatestFiniteMagnitude)
        for index in 1...2 {
            await ledger.stage(sourceMessageId: "m\(index)", authorId: "u1", state: Self.state, action: 0, now: Self.t0)
            await ledger.bind(sourceMessageId: "m\(index)", replyMessageId: "r\(index)", now: Self.t0)
        }
        let agent = DQNAgent(seed: 7, experiencePersistence: nil)

        let single = try JSONDecoder().decode(
            Gateway.MessageDelete.self,
            from: Data(#"{"id":"r1","channel_id":"10","guild_id":"20"}"#.utf8)
        )
        #expect(await ReplyDeletionIngress.apply(single, ledger: ledger, dqnAgent: agent) == 1)
        #expect(await ReplyDeletionIngress.apply(single, ledger: ledger, dqnAgent: agent) == 0)

        let bulk = try JSONDecoder().decode(
            Gateway.MessageDeleteBulk.self,
            from: Data(#"{"ids":["r1","r2","x"],"channel_id":"10","guild_id":"20"}"#.utf8)
        )
        #expect(await ReplyDeletionIngress.apply(bulk, ledger: ledger, dqnAgent: agent) == 1)
        #expect(await agent.bufferCount() == 2)
    }

    // MARK: - Confirmed moderation

    @Test func moderationRewardsTargetSamplesByStrategy() async {
        let ledger = DelayedRewardLedger(timeToLive: 3_600)
        let strategies: [StrategyAction] = [.answer, .refuse, .retrieve, .clarify]
        for (index, strategy) in strategies.enumerated() {
            await ledger.stage(sourceMessageId: "m\(index)", authorId: "bad", guildId: "g1",
                               state: Self.state, action: strategy.rawValue,
                               now: Self.t0.addingTimeInterval(Double(index)))
        }
        // One of the target's samples already has a delivered reply.
        await ledger.bind(sourceMessageId: "m3", replyMessageId: "r3", now: Self.t0)
        await ledger.stage(sourceMessageId: "o1", authorId: "bad", guildId: "g2", state: Self.state, action: 0, now: Self.t0)
        await ledger.stage(sourceMessageId: "o2", authorId: "good", guildId: "g1", state: Self.state, action: 0, now: Self.t0)

        let paid = await ledger.consumeModeration(targetUserId: "bad", guildId: "g1", now: Self.t0.addingTimeInterval(10))
        #expect(paid.map(\.reward).sorted() == [-1, -1, 1])
        #expect(paid.allSatisfy { $0.done && $0.nextState == $0.state })
        // retrieve kept, other guild kept, other user kept; bound clarify consumed.
        #expect(await ledger.stagedCount == 3)
        #expect(await ledger.boundCount == 0)
        #expect(await ledger.consumeModeration(targetUserId: "bad", guildId: "g1",
                                               now: Self.t0.addingTimeInterval(10)).isEmpty)
    }

    @Test func moderationHonoursCapAndLifetime() async {
        let ledger = DelayedRewardLedger(capacity: 64, timeToLive: 100)
        for index in 0..<30 {
            await ledger.stage(sourceMessageId: "m\(index)", authorId: "bad", guildId: "g",
                               state: Self.state, action: StrategyAction.answer.rawValue,
                               now: Self.t0.addingTimeInterval(Double(index)))
        }
        // At t0+105 the samples staged before t0+5 are expired.
        let paid = await ledger.consumeModeration(targetUserId: "bad", guildId: "g", now: Self.t0.addingTimeInterval(105))
        #expect(paid.count == DelayedRewardLedger.moderationPayoutLimit)
        let rest = await ledger.consumeModeration(targetUserId: "bad", guildId: "g", now: Self.t0.addingTimeInterval(105))
        #expect(rest.count == 25 - DelayedRewardLedger.moderationPayoutLimit)
        #expect(await ledger.consumeModeration(targetUserId: "", guildId: "g").isEmpty)
    }

    @Test func moderationIngressTrainsTheAgent() async {
        let ledger = DelayedRewardLedger(timeToLive: .greatestFiniteMagnitude)
        await ledger.stage(sourceMessageId: "m1", authorId: "bad", guildId: "g", state: Self.state,
                           action: StrategyAction.refuse.rawValue, now: Self.t0)
        let agent = DQNAgent(seed: 7, experiencePersistence: nil)
        #expect(await ModerationRewardIngress.apply(targetUserId: "bad", guildId: "g", ledger: ledger, dqnAgent: agent) == 1)
        #expect(await agent.bufferCount() == 1)
    }

    @Test func gatewayReactionTrainsTheAgent() async throws {
        // `apply` reads the wall clock, so the fixed test epoch needs an unbounded lifetime.
        let ledger = await boundLedger(action: 1, timeToLive: .greatestFiniteMagnitude)
        let agent = DQNAgent(seed: 7, experiencePersistence: nil)
        let before = await agent.bufferCount()

        let json = """
        {"type":0,"user_id":"u1","channel_id":"10","message_id":"r1","guild_id":"20",
         "member":{"roles":[]},"emoji":{"id":null,"name":"🔥"}}
        """
        let payload = try JSONDecoder().decode(Gateway.MessageReactionAdd.self, from: Data(json.utf8))
        let applied = await ReactionRewardIngress.apply(payload, botUserId: "bot", ledger: ledger, dqnAgent: agent)
        #expect(applied)
        #expect(await agent.bufferCount() == before + 1)

        let replay = await ReactionRewardIngress.apply(payload, botUserId: "bot", ledger: ledger, dqnAgent: agent)
        #expect(!replay)
        #expect(await agent.bufferCount() == before + 1)
    }
}
