import AbbeyCore
import Foundation
import Testing
@testable import AbbeyQuasarKit

struct QuasarApprovalBudgetTests {
    @Test func concurrentApprovalsCannotSpendOneRemainingBudgetTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try QuasarService(home: root, planner: planner)
        let proposals = try await proposePair(service)
        let barrier = ApprovalBarrier()
        let first = Task {
            try await service.approveDiscordProposal(
                id: proposals[0].id, digest: proposals[0].digest, revalidated: facts,
                beforeAuthorization: { await barrier.suspend() }
            )
        }
        await barrier.waitUntilEntered()
        await #expect(throws: QuasarError.self) {
            _ = try await service.approveDiscordProposal(
                id: proposals[1].id, digest: proposals[1].digest, revalidated: facts
            )
        }
        await barrier.release()
        _ = try await first.value
        #expect(await service.listSites().count == 1)
        await service.shutdown()
    }

    @Test func failedAuthorizationRefundsReservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try QuasarService(home: root, planner: planner)
        let proposals = try await proposePair(service)
        await #expect(throws: QuasarError.proposalChanged) {
            _ = try await service.approveDiscordProposal(id: proposals[0].id, digest: "wrong", revalidated: facts)
        }
        _ = try await service.approveDiscordProposal(id: proposals[1].id, digest: proposals[1].digest, revalidated: facts)
        #expect(await service.listSites().count == 1)
        await service.shutdown()
    }

    @Test func authorizedEffectFailureDoesNotRefundPotentiallySpentBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try QuasarService(home: root, planner: planner)
        _ = await service.handleDiscord(.init(action: .previewStop, siteID: "missing-site",
            initiatorID: facts.initiatorID, guildID: facts.guildID, managerAuthorized: true), facts: facts)
        let proposal = try #require(await service.pendingDiscordProposals().first)
        await #expect(throws: QuasarError.notFound) {
            _ = try await service.approveDiscordProposal(id: proposal.id, digest: proposal.digest, revalidated: facts)
        }
        _ = await service.handleDiscord(.init(action: .create, name: "After failure", prompt: "page",
            initiatorID: facts.initiatorID, guildID: facts.guildID, managerAuthorized: true), facts: facts)
        #expect(await service.pendingDiscordProposals().isEmpty)
        #expect(await service.listSites().isEmpty)
        await service.shutdown()
    }

    private func proposePair(_ service: QuasarService) async throws -> [QuasarProposal] {
        for name in ["First", "Second"] {
            _ = await service.handleDiscord(.init(action: .create, name: name, prompt: "page",
                initiatorID: facts.initiatorID, guildID: facts.guildID, managerAuthorized: true), facts: facts)
        }
        let proposals = await service.pendingDiscordProposals()
        try #require(proposals.count == 2)
        return proposals
    }

    private var facts: QuasarAuthorizationFacts {
        .init(guildID: "budget-guild", initiatorID: "operator", ownerAllowed: true,
              discordPermissionAllowed: true, guildOptedIn: true, quiet: false, remainingBudget: 1)
    }
    private var planner: QuasarPlanner {
        .init(readPlan: { _, _ in .init(paths: []) }, mutationPlan: { _, _ in
            .init(summary: "page", operations: [.write(path: "proof.txt", content: "approved")], idempotencyKey: "budget")
        })
    }
}

private actor ApprovalBarrier {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
