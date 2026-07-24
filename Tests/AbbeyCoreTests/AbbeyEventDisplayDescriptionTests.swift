import Testing
@testable import AbbeyCore

@Suite("AbbeyEvent.displayDescription")
struct AbbeyEventDisplayDescriptionTests {
    @Test func allCasesAreReadable() {
        let cases: [(AbbeyEvent, String)] = [
            (
                .messageIngested(channelId: "c1", guildId: "g1", authorId: "a1"),
                "Ingested message from a1 in channel c1 (g1)"
            ),
            (
                .reputationChanged(userId: "u1", guildId: "g1", newValue: 0.5, reason: "upvote"),
                "Reputation u1 → 0.50 (upvote)"
            ),
            (
                .channelContextConsolidated(channelId: "c1", messageCount: 12),
                "Consolidated channel c1 (12 msgs)"
            ),
            (.personaSwitched(to: "Aviva"), "Persona → Aviva"),
            (
                .destructiveActionRequested(kind: .kick, targetUserId: "u1", guildId: "g1"),
                "Confirm kick for u1?"
            ),
            (
                .destructiveActionConfirmed(kind: .ban, targetUserId: "u1", guildId: "g1"),
                "Confirmed ban for u1"
            ),
            (
                .destructiveActionCancelled(kind: .purge, targetUserId: "u1"),
                "Cancelled purge for u1"
            ),
            (.equityIdeaGenerated(symbol: "AAPL"), "Equity idea AAPL"),
            (
                .inferenceProviderFailed(mode: .deterministicFloor, message: "timeout"),
                "Inference failed (deterministicFloor): timeout"
            ),
        ]

        for (event, expected) in cases {
            #expect(event.displayDescription == expected)
            #expect(!event.displayDescription.hasPrefix("AbbeyEvent."))
            #expect(!event.displayDescription.contains("channelId:"))
        }
    }
}
