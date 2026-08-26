import AbbeyCore
import Foundation
import Testing
@testable import AbbeyQuasarKit

@Suite("Quasar two-stage approval")
struct QuasarApprovalWorkflowTests {
    @Test func fullCreateApprovePreviewEditRollbackArchiveLifecycle() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let planCounter = PlanCounter()
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { _, _ in
                let round = await planCounter.next()
                return .init(
                    summary: "round \(round)",
                    operations: [.write(path: "operator-proof.txt", content: "round-\(round)")],
                    idempotencyKey: "lifecycle-\(round)"
                )
            }
        )
        let preview = QuasarPreviewManager(
            readinessAttempts: 2,
            pollInterval: .milliseconds(10),
            command: .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: { _ in ["sleep", "30"] }
            ),
            readinessProbe: { _ in true }
        )
        let service = try QuasarService(home: base, planner: planner, preview: preview)

        let site = try await service.create(name: "Lifecycle", prompt: "first")
        let firstPlan = try await waitForPlan(service: service, siteID: site.id)
        let firstReceipt = try await service.approve(id: site.id, planDigest: firstPlan.planDigest)
        let eventPage = try await service.events(id: site.id, since: 0)
        #expect(eventPage.events.contains { $0.type == .done })

        let running = try await service.startPreview(id: site.id)
        #expect(running.state == .running)
        #expect(try await service.previewStatus(id: site.id).state == .running)
        #expect(try await service.stopPreview(id: site.id).state == .stopped)

        _ = try await service.edit(id: site.id, prompt: "second")
        let secondPlan = try await waitForPlan(service: service, siteID: site.id)
        let secondReceipt = try await service.approve(id: site.id, planDigest: secondPlan.planDigest)
        let proof = base.appendingPathComponent("sites/lifecycle/operator-proof.txt")
        #expect(try String(contentsOf: proof, encoding: .utf8) == "round-2")
        let rollback = try await service.rollback(id: site.id, planDigest: secondReceipt.planDigest)
        #expect(rollback.restoredPaths == ["operator-proof.txt"])
        #expect(try String(contentsOf: proof, encoding: .utf8) == "round-1")
        #expect(firstReceipt.planDigest != secondReceipt.planDigest)

        let archive = try await service.archive(id: site.id)
        #expect(archive.siteID == site.id)
        #expect(archive.contentDigest.count == 64)
        #expect(archive.archiveDigest.count == 64)
        await #expect(throws: QuasarError.self) { _ = try await service.site(id: site.id) }

        var tampered = archive
        tampered.archiveDigest = String(repeating: "0", count: 64)
        await #expect(throws: QuasarError.self) { _ = try await service.restore(tampered) }

        let archivedProof = base.appendingPathComponent(
            "archive/\(archive.archiveName)/operator-proof.txt"
        )
        try Data("tampered".utf8).write(to: archivedProof, options: .atomic)
        await #expect(throws: QuasarError.self) { _ = try await service.restore(archive) }
        try Data("round-1".utf8).write(to: archivedProof, options: .atomic)

        let restored = try await service.restore(archive)
        #expect(restored.id == site.id)
        #expect(restored.status == .idle)
        #expect(restored.previewPort == nil)
        #expect(try String(contentsOf: proof, encoding: .utf8) == "round-1")
        await #expect(throws: QuasarError.self) { _ = try await service.restore(archive) }
        await service.shutdown()
    }

    @Test func failedPreviewStartupReleasesItsRegistryPort() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { _, _ in
                .init(
                    summary: "ready",
                    operations: [.write(path: "ready.txt", content: "ready")],
                    idempotencyKey: "failed-preview"
                )
            }
        )
        let preview = QuasarPreviewManager(
            readinessAttempts: 1,
            pollInterval: .milliseconds(1),
            command: .init(
                executableURL: URL(fileURLWithPath: "/definitely/missing/quasar-preview"),
                arguments: { _ in [] }
            ),
            readinessProbe: { _ in false }
        )
        let service = try QuasarService(home: base, planner: planner, preview: preview)
        let site = try await service.create(name: "Preview Failure", prompt: "prepare")
        let plan = try await waitForPlan(service: service, siteID: site.id)
        _ = try await service.approve(id: site.id, planDigest: plan.planDigest)

        #expect(try await service.startPreview(id: site.id).state == .crashed)
        #expect(try await service.site(id: site.id).previewPort == nil)
    }

    @Test func generatedMutationDoesNotWriteBeforeExactDigestApproval() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { _, _ in
                .init(
                    summary: "add operator proof",
                    operations: [.write(path: "operator-proof.txt", content: "approved")],
                    idempotencyKey: "approval-workflow-1"
                )
            }
        )
        let service = try QuasarService(home: base, planner: planner)
        let site = try await service.create(name: "Approval Test", prompt: "Add proof")
        let target = base.appendingPathComponent("sites/approval-test/operator-proof.txt")

        var pending: QuasarMutationPreview?
        for _ in 0..<100 where pending == nil {
            pending = try await service.pendingPlan(id: site.id)
            if pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let plan = try #require(pending)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        let receipt = try await service.approve(id: site.id, planDigest: plan.planDigest)
        #expect(receipt.planDigest == plan.planDigest)
        #expect(try String(contentsOf: target, encoding: .utf8) == "approved")
        #expect(try await service.site(id: site.id).status == .idle)
    }

    @Test func rollbackReceiptCannotCrossSiteBoundary() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { prompt, _ in
                .init(
                    summary: prompt,
                    operations: [.write(path: "site-proof.txt", content: prompt)],
                    idempotencyKey: prompt
                )
            }
        )
        let service = try QuasarService(home: base, planner: planner)

        let first = try await service.create(name: "First Site", prompt: "first-site-plan")
        let firstPlan = try await waitForPlan(service: service, siteID: first.id)
        let firstReceipt = try await service.approve(
            id: first.id,
            planDigest: firstPlan.planDigest
        )
        let second = try await service.create(name: "Second Site", prompt: "second-site-plan")
        let secondPlan = try await waitForPlan(service: service, siteID: second.id)
        _ = try await service.approve(id: second.id, planDigest: secondPlan.planDigest)

        await #expect(throws: QuasarError.notFound) {
            _ = try await service.rollback(
                id: second.id,
                planDigest: firstReceipt.planDigest
            )
        }
        let secondProof = base.appendingPathComponent("sites/second-site/site-proof.txt")
        #expect(try String(contentsOf: secondProof, encoding: .utf8) == "second-site-plan")
        #expect(firstReceipt.rollbackDirectory.contains("/\(first.id)/"))
    }

    @Test func discordQuasarPolicyIsDefaultOffAndQuietIsHigherOrderDenial() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = try QuasarService(
            home: base,
            planner: .init(readPlan: { _, _ in .init(paths: []) }, mutationPlan: { _, _ in
                .init(summary: "noop", operations: [.write(path: "x", content: "x")], idempotencyKey: "x")
            })
        )
        let request = DiscordQuasarRequest(
            action: .create,
            name: "Denied",
            prompt: "Denied",
            initiatorID: "owner",
            guildID: "guild",
            managerAuthorized: true
        )
        let defaultFacts = QuasarAuthorizationFacts.current(
            guildID: "guild",
            initiatorID: "owner",
            discordPermissionAllowed: true,
            environment: [:]
        )
        #expect(!(await service.handleDiscord(request, facts: defaultFacts)).contains("created"))

        let quietFacts = QuasarAuthorizationFacts.current(
            guildID: "guild",
            initiatorID: "owner",
            discordPermissionAllowed: true,
            environment: [
                "DISCORD_OPERATOR_USER_IDS": "owner",
                "ABBEY_QUASAR_GUILD_IDS": "guild",
                "ABBEY_QUASAR_GUILD_BUDGET": "2",
                "ABBEY_QUIET": "true",
            ]
        )
        #expect(!quietFacts.permitsMutation)
        #expect(!(await service.handleDiscord(request, facts: quietFacts)).contains("created"))

        let list = DiscordQuasarRequest(
            action: .list,
            initiatorID: "owner",
            guildID: "guild",
            managerAuthorized: true
        )
        #expect(!defaultFacts.permitsRead)
        #expect((await service.handleDiscord(list, facts: defaultFacts)).contains("denied"))
        #expect(!quietFacts.permitsRead)
        #expect((await service.handleDiscord(list, facts: quietFacts)).contains("denied"))

        var readFacts = quietFacts
        readFacts.quiet = false
        readFacts.remainingBudget = 0
        #expect(readFacts.permitsRead)
        #expect(!readFacts.permitsMutation)
        #expect(await service.handleDiscord(list, facts: readFacts) == "No Quasar sites are registered.")
    }

    @Test func rejectedPlannerCannotOverwriteANewerGenerationWhenItReturnsLate() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let firstRead = FirstReadGate()
        let planner = QuasarPlanner(
            readPlan: { _, _ in
                await firstRead.readPlan()
            },
            mutationPlan: { prompt, _ in
                .init(
                    summary: prompt,
                    operations: [.write(path: "generation.txt", content: prompt)],
                    idempotencyKey: prompt
                )
            }
        )
        let service = try QuasarService(home: base, planner: planner)

        let site = try await service.create(name: "Generation", prompt: "stale")
        await firstRead.waitUntilStarted()
        try await service.reject(id: site.id)

        _ = try await service.edit(id: site.id, prompt: "current")
        let current = try await waitForPlan(service: service, siteID: site.id)
        #expect(current.summary == "current")

        await firstRead.release()
        try await Task.sleep(for: .milliseconds(50))

        let stillCurrent = try #require(try await service.pendingPlan(id: site.id))
        #expect(stillCurrent.planDigest == current.planDigest)
        #expect(try await service.site(id: site.id).status == .generating)
    }
}

private actor PlanCounter {
    private var value = 0
    func next() -> Int { value += 1; return value }
}

private actor FirstReadGate {
    private var callCount = 0
    private var firstStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func readPlan() async -> QuasarReadPlan {
        callCount += 1
        guard callCount == 1 else { return .init(paths: []) }
        firstStarted = true
        await withCheckedContinuation { continuation = $0 }
        return .init(paths: [])
    }

    func waitUntilStarted() async {
        while !firstStarted { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private func waitForPlan(service: QuasarService, siteID: String) async throws -> QuasarMutationPreview {
    for _ in 0..<100 {
        if let plan = try await service.pendingPlan(id: siteID) { return plan }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw QuasarError.processFailed("timed out waiting for mutation plan")
}
