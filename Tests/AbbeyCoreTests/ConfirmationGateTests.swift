import Foundation
import Testing
@testable import AbbeyCore

/// `ConfirmationGate` is the only path to kick, ban and purge. Its confirmed path is covered by
/// `AbbeyEngineModerationRewardTests`; these tests pin the branch where no human is asked.
@Suite("Confirmation gate events")
struct ConfirmationGateTests {
    /// Collects the destructive-action events published while `body` runs.
    private func destructiveEvents(
        on bus: EventBus,
        during body: () async -> Void
    ) async -> [String] {
        let stream = await bus.subscribe()
        await body()
        await bus.publish(.personaSwitched(to: "end-of-test"))
        var seen: [String] = []
        for await event in stream {
            switch event {
            case .destructiveActionRequested(let kind, let target, let guild):
                seen.append("requested \(kind.rawValue) \(target) \(guild)")
            case .destructiveActionConfirmed(let kind, let target, let guild):
                seen.append("confirmed \(kind.rawValue) \(target) \(guild)")
            case .destructiveActionCancelled(let kind, let target):
                seen.append("cancelled \(kind.rawValue) \(target)")
            case .personaSwitched:
                return seen
            default:
                continue
            }
        }
        return seen
    }

    /// With confirmation off a purge goes ahead, so it must be reported as confirmed. Without
    /// that event the desktop engine neither counts the action in its metrics nor applies the
    /// moderation reward, even though the purge really happened.
    @Test func bypassApprovesAPurgeAndReportsItAsConfirmed() async {
        let bus = EventBus()
        let gate = ConfirmationGate(eventBus: bus, requireConfirmation: { false })
        var approved = false

        let events = await destructiveEvents(on: bus) {
            approved = await gate.request(kind: .purge, targetUserId: "u1", guildId: "g1", reason: "spam")
        }

        #expect(approved)
        #expect(await gate.queue.isEmpty)
        #expect(events == ["requested purge u1 g1", "confirmed purge u1 g1"])
    }

    /// Kick and ban ignore the setting: they always queue for a human.
    @Test(arguments: [DestructiveAction.kick, .ban])
    func memberRemovalAlwaysWaitsForTheSheet(kind: DestructiveAction) async {
        let bus = EventBus()
        let gate = ConfirmationGate(eventBus: bus, requireConfirmation: { false })
        var approved = true

        let events = await destructiveEvents(on: bus) {
            let request = Task {
                await gate.request(kind: kind, targetUserId: "u3", guildId: "g3", reason: "test")
            }
            var pending: UUID?
            for _ in 0..<200 where pending == nil {
                pending = await gate.queue.first?.id
                if pending == nil { try? await Task.sleep(for: .milliseconds(5)) }
            }
            #expect(pending != nil, "\(kind.rawValue) must queue even with confirmation off")
            if let pending { await gate.cancel(pending) }
            approved = await request.value
        }

        #expect(!approved)
        #expect(events == ["requested \(kind.rawValue) u3 g3", "cancelled \(kind.rawValue) u3"])
    }

    @Test func requiredConfirmationReportsRequestThenConfirmation() async {
        let bus = EventBus()
        let gate = ConfirmationGate(eventBus: bus, requireConfirmation: { true })
        var approved = false

        let events = await destructiveEvents(on: bus) {
            let request = Task {
                await gate.request(kind: .kick, targetUserId: "u2", guildId: "g2", reason: "raid")
            }
            var pending: UUID?
            for _ in 0..<200 where pending == nil {
                pending = await gate.queue.first?.id
                if pending == nil { try? await Task.sleep(for: .milliseconds(5)) }
            }
            if let pending { await gate.confirm(pending) }
            approved = await request.value
        }

        #expect(approved)
        #expect(events == ["requested kick u2 g2", "confirmed kick u2 g2"])
    }
}

@Suite("Settings keys that ignore the environment")
struct AppConfigEnvironmentScopeTests {
    /// Settings used to label these keys "Env:", but `AppConfig` reads them from UserDefaults
    /// only. The captions now say "UserDefaults key:"; if one of these starts honouring the
    /// environment, move it back to "Env:" in `SettingsView` and out of this list.
    @Test func settingsKeysThatIgnoreTheEnvironment() throws {
        let scratch = try ScratchDefaults("ConfirmationGateTests.env")
        defer { scratch.remove() }
        let config = AppConfig(
            defaults: scratch.defaults,
            environment: [
                "ABBEY_OPERATING_MODE": "liveDiscord",
                "ABBEY_REPLY_COOLDOWN_SECONDS": "99",
                "ABBEY_MEMORY_CONSOLIDATION_INTERVAL_MIN": "99",
                "ABBEY_REPUTATION_DECAY": "0.5",
                "ABBEY_CONFIRMATION_REQUIRED": "0",
                "ABBEY_EQUITY_MODULE_ENABLED": "0",
            ],
            tokens: InMemoryTokenStore()
        )

        #expect(config.operatingMode == .standalone)
        #expect(config.replyCooldownSeconds == 8.0)
        #expect(config.memoryConsolidationIntervalMinutes == 15.0)
        #expect(config.reputationDecay == 0.95)
        #expect(config.confirmationRequiredForDestructiveActions == true)
        #expect(config.equityModuleEnabled == true)
    }
}
