import Testing
@testable import AbbeyCLI
import Foundation

@Suite("CLISyncPushPlan")
struct CLISyncPushPlanTests {
    @Test func ordersMessagesByCreatedAtAndDropsTombstones() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let plan = CLISyncPushPlan.build(
            messages: [
                (createdAt: newer, discordMessageId: "m2", content: "second", channelId: "c", guildId: "g", authorId: "u", deletedAt: nil),
                (createdAt: older, discordMessageId: "m1", content: "first", channelId: "c", guildId: "g", authorId: "u", deletedAt: nil),
                (createdAt: newer, discordMessageId: "m3", content: "gone", channelId: "c", guildId: "g", authorId: "u", deletedAt: newer)
            ],
            memories: []
        )
        #expect(plan.messages.map(\.discordMessageId) == ["m1", "m2"])
        #expect(plan.facts.isEmpty)
    }

    @Test func expandsFactsInArrayOrderAndSkipsEmpty() {
        let plan = CLISyncPushPlan.build(
            messages: [],
            memories: [
                (
                    updatedAt: Date(timeIntervalSince1970: 50),
                    discordUserId: "u1",
                    guildId: "g1",
                    facts: ["likes tea", "   ", "lives in nyc"],
                    deletedAt: nil
                ),
                (
                    updatedAt: Date(timeIntervalSince1970: 10),
                    discordUserId: "u0",
                    guildId: "g1",
                    facts: ["earlier user"],
                    deletedAt: nil
                ),
                (
                    updatedAt: Date(timeIntervalSince1970: 90),
                    discordUserId: "ghost",
                    guildId: "g1",
                    facts: ["should not push"],
                    deletedAt: Date()
                )
            ]
        )
        #expect(plan.facts == [
            .init(userId: "u0", guildId: "g1", fact: "earlier user"),
            .init(userId: "u1", guildId: "g1", fact: "likes tea"),
            .init(userId: "u1", guildId: "g1", fact: "lives in nyc")
        ])
    }

    @Test func emptyInputsYieldEmptyPlan() {
        let plan = CLISyncPushPlan.build(messages: [], memories: [])
        #expect(plan.messages.isEmpty)
        #expect(plan.facts.isEmpty)
    }
}
