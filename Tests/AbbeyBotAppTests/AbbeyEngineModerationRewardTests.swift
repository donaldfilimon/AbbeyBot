import AbbeyCore
import Foundation
import SwiftData
import Testing
@testable import AbbeyBotApp

@MainActor
@Suite("AbbeyEngine moderation rewards", .serialized)
struct AbbeyEngineModerationRewardTests {
    private static let state: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]

    private func makeEngine() throws -> AbbeyEngine {
        let schema = Schema([
            GuildMessage.self,
            UserMemory.self,
            ChannelContext.self,
            ReputationEvent.self,
            InteractionLog.self,
            EquityIdea.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let suite = "AbbeyEngineModerationRewardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let config = AppConfig(defaults: defaults, environment: [:], tokens: InMemoryTokenStore())
        config.confirmationRequiredForDestructiveActions = true
        // An injected agent with no checkpoint and no journal keeps `~/.abbey` untouched.
        return AbbeyEngine(
            modelContainer: container,
            config: config,
            dqnAgent: DQNAgent(seed: 7, experiencePersistence: nil)
        )
    }

    /// Requests a kick through the real gate and resolves it once it is queued.
    private func resolveKick(on engine: AbbeyEngine, confirm: Bool) async -> Bool {
        let gate = engine.confirmationGate
        let request = Task {
            await gate.request(kind: .kick, targetUserId: "bad", guildId: "g", reason: "test")
        }
        for _ in 0..<200 {
            if let pending = await gate.queue.first {
                if confirm { await gate.confirm(pending.id) } else { await gate.cancel(pending.id) }
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await request.value
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @Test func confirmedKickRewardsTheTargetsSamples() async throws {
        let engine = try makeEngine()
        let before = await engine.dqnAgent.bufferCount()
        await engine.rewardLedger.stage(sourceMessageId: "m1", authorId: "bad", guildId: "g",
                                        state: Self.state, action: StrategyAction.answer.rawValue)

        #expect(await resolveKick(on: engine, confirm: true))
        #expect(await waitUntil { await engine.rewardLedger.stagedCount == 0 })
        #expect(await engine.dqnAgent.bufferCount() == before + 1)
        await engine.shutdown()
    }

    @Test func cancelledKickLeavesSamplesAlone() async throws {
        let engine = try makeEngine()
        let before = await engine.dqnAgent.bufferCount()
        await engine.rewardLedger.stage(sourceMessageId: "m1", authorId: "bad", guildId: "g",
                                        state: Self.state, action: StrategyAction.answer.rawValue)

        #expect(await resolveKick(on: engine, confirm: false) == false)
        // Give the event listener time to (not) act on the cancellation.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await engine.rewardLedger.stagedCount == 1)
        #expect(await engine.dqnAgent.bufferCount() == before)
        await engine.shutdown()
    }
}
