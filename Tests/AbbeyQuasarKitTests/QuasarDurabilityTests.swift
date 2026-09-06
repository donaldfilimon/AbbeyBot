import Foundation
import Testing
@testable import AbbeyQuasarKit

@Suite("Quasar durable approval and recovery")
struct QuasarDurabilityTests {
    @Test func reviewContainsCompleteBeforeAndAfterAndRejectsChangedPreimage() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { _, _ in
                .init(
                    summary: "replace page and add stylesheet",
                    operations: [
                        .write(path: "app/page.tsx", content: "export default function Page() { return <p>after</p> }"),
                        .write(path: "app/new.css", content: "p { color: teal; }"),
                    ],
                    idempotencyKey: "review-preimage"
                )
            }
        )
        let service = try QuasarService(home: base, planner: planner)
        let site = try await service.create(name: "Review", prompt: "replace page")
        let page = base.appendingPathComponent("sites/review/app/page.tsx")
        let original = try String(contentsOf: page, encoding: .utf8)
        let review = try #require(try await waitForReview(service: service, siteID: site.id))

        #expect(review.siteID == site.id)
        #expect(!review.generationID.isEmpty)
        #expect(review.files == [
            .init(kind: .write, path: "app/page.tsx", before: original, after: "export default function Page() { return <p>after</p> }"),
            .init(kind: .write, path: "app/new.css", before: nil, after: "p { color: teal; }"),
        ])

        try Data("operator edit".utf8).write(to: page, options: .atomic)
        await #expect(throws: QuasarError.proposalChanged) {
            _ = try await service.approve(id: site.id, planDigest: review.planDigest)
        }
        #expect(try String(contentsOf: page, encoding: .utf8) == "operator edit")
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("sites/review/app/new.css").path))
    }

    @Test func planDigestBindsGenerationAndApprovalExpiryPreventsWrites() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let siteRoot = base.appendingPathComponent("site")
        let rollbackRoot = base.appendingPathComponent("rollback")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: siteRoot, withIntermediateDirectories: true)
        let plan = QuasarMutationPlan(
            summary: "write",
            operations: [.write(path: "proof.txt", content: "approved")],
            idempotencyKey: "expiry"
        )
        let executor = QuasarMutationExecutor()
        let first = try await executor.review(
            plan,
            siteID: "site",
            generationID: "generation-one",
            siteRoot: siteRoot,
            createdAt: Date(timeIntervalSince1970: 100),
            lifetime: .seconds(5)
        )
        let second = try await executor.review(
            plan,
            siteID: "site",
            generationID: "generation-two",
            siteRoot: siteRoot,
            createdAt: Date(timeIntervalSince1970: 100),
            lifetime: .seconds(5)
        )
        #expect(first.planDigest != second.planDigest)

        await #expect(throws: QuasarError.proposalExpired) {
            _ = try await executor.apply(
                plan,
                approvedReview: first,
                to: siteRoot,
                rollbackRoot: rollbackRoot,
                now: Date(timeIntervalSince1970: 106)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: siteRoot.appendingPathComponent("proof.txt").path))
        #expect(!FileManager.default.fileExists(atPath: rollbackRoot.path))
    }

    @Test func mutationAndRollbackOutcomesPersistInHistory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { _, _ in
                .init(
                    summary: "record me",
                    operations: [.write(path: "history.txt", content: "new")],
                    idempotencyKey: "history"
                )
            }
        )
        let service = try QuasarService(home: base, planner: planner)
        let site = try await service.create(name: "History", prompt: "record")
        let review = try #require(try await waitForReview(service: service, siteID: site.id))
        _ = try await service.approve(id: site.id, planDigest: review.planDigest)
        _ = try await service.rollback(id: site.id, planDigest: review.planDigest)

        let history = try await service.history(id: site.id)
        #expect(history.map(\.kind) == [.mutation, .rollback])
        #expect(history.map(\.status) == [.succeeded, .succeeded])
        #expect(history.allSatisfy { $0.schemaVersion == 1 && $0.finishedAt != nil })

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(
            [QuasarHistoryRecord].self,
            from: Data(contentsOf: base.appendingPathComponent("history/\(site.id).json"))
        )
        #expect(persisted == history)
    }

    @Test func restartMarksInterruptedEffectsUncertainWithExplicitProblem() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let historyRoot = base.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        let interrupted = QuasarHistoryRecord(
            id: "operation",
            siteID: "site",
            generationID: "generation",
            kind: .mutation,
            status: .applying,
            planDigest: String(repeating: "a", count: 64),
            paths: ["page.txt"],
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([interrupted]).write(
            to: historyRoot.appendingPathComponent("site.json"),
            options: .atomic
        )

        let store = try QuasarHistoryStore(home: base)
        let recovered = try store.history(siteID: "site")
        #expect(recovered.count == 1)
        #expect(recovered[0].status == .uncertain)
        #expect(recovered[0].problem?.code == .interruptedEffect)
        #expect(recovered[0].problem?.requiresOperatorReview == true)
        #expect(recovered[0].finishedAt != nil)
    }

    @Test func archiveDiscoveryVerifiesContentsAndOmitsReproducibleDependencies() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { _, _ in
                .init(summary: "ready", operations: [.write(path: "proof.txt", content: "proof")], idempotencyKey: "archive")
            }
        )
        let service = try QuasarService(home: base, planner: planner)
        let site = try await service.create(name: "Archive", prompt: "ready")
        let review = try #require(try await waitForReview(service: service, siteID: site.id))
        _ = try await service.approve(id: site.id, planDigest: review.planDigest)
        let root = base.appendingPathComponent("sites/archive")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try Data("dependency".utf8).write(to: root.appendingPathComponent("node_modules/pkg/index.js"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".next/cache"), withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: root.appendingPathComponent(".next/cache/data"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".quasar-runtime/cache"), withIntermediateDirectories: true)
        try Data("runtime".utf8).write(to: root.appendingPathComponent(".quasar-runtime/cache/data"))

        let receipt = try await service.archive(id: site.id)
        let archivedRoot = base.appendingPathComponent("archive/\(receipt.archiveName)")
        #expect(!FileManager.default.fileExists(atPath: archivedRoot.appendingPathComponent("node_modules").path))
        #expect(!FileManager.default.fileExists(atPath: archivedRoot.appendingPathComponent(".next").path))
        #expect(!FileManager.default.fileExists(atPath: archivedRoot.appendingPathComponent(".quasar-runtime").path))
        #expect(try await service.archives() == [receipt])

        try Data("tampered".utf8).write(to: archivedRoot.appendingPathComponent("proof.txt"), options: .atomic)
        #expect(try await service.archives().isEmpty)
    }

    @Test func serviceIdentityIsStableForOneHome() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { _, _ in .init(summary: "x", operations: [.write(path: "x", content: "x")], idempotencyKey: "x") }
        )
        var first: QuasarService? = try QuasarService(home: base, planner: planner)
        let identity = try await first?.serviceIdentity()
        #expect(identity?.hasPrefix("quasar-") == true)
        await first?.shutdown()
        first = nil

        let second = try QuasarService(home: base, planner: planner)
        #expect(try await second.serviceIdentity() == identity)
    }

    @Test func unresolvedEffectBlocksNewWorkUntilOperatorReconcilesIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { prompt, _ in
                .init(summary: prompt, operations: [.write(path: "x", content: prompt)], idempotencyKey: prompt)
            }
        )
        let service = try QuasarService(home: base, planner: planner)
        let site = try await service.create(name: "Recovery", prompt: "first")
        let review = try #require(try await waitForReview(service: service, siteID: site.id))
        _ = try await service.approve(id: site.id, planDigest: review.planDigest)

        let store = try QuasarHistoryStore(home: base)
        let interrupted = try store.begin(siteID: site.id, kind: .archive, paths: [])
        _ = try store.finish(
            interrupted.id,
            siteID: site.id,
            status: .uncertain,
            problem: .init(code: .interruptedEffect, message: "inspect")
        )

        await #expect(throws: QuasarError.self) {
            _ = try await service.edit(id: site.id, prompt: "blocked")
        }
        let reconciled = try await service.reconcileRecovery(
            id: site.id,
            recordID: interrupted.id,
            resolution: .confirmedNotApplied
        )
        #expect(reconciled.status == .reconciled)
        #expect(reconciled.problem?.requiresOperatorReview == false)
        _ = try await service.edit(id: site.id, prompt: "allowed")
    }

    @Test func confirmedAppliedRecoveryRetainsTheEffectiveMutationStack() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try QuasarHistoryStore(home: base)
        let digest = String(repeating: "a", count: 64)
        let mutation = try store.begin(
            siteID: "site-one",
            generationID: "generation-one",
            kind: .mutation,
            planDigest: digest,
            paths: ["index.html"]
        )
        _ = try store.finish(
            mutation.id,
            siteID: "site-one",
            status: .uncertain,
            problem: .init(code: .interruptedEffect, message: "inspect")
        )

        let reconciledMutation = try store.reconcile(
            siteID: "site-one",
            recordID: mutation.id,
            resolution: .confirmedApplied
        )
        #expect(reconciledMutation.status == .reconciled)
        #expect(reconciledMutation.recoveryResolution == .confirmedApplied)
        #expect(try store.currentMutation(siteID: "site-one")?.id == mutation.id)

        let rollback = try store.begin(
            siteID: "site-one",
            kind: .rollback,
            planDigest: digest,
            paths: ["index.html"]
        )
        _ = try store.finish(
            rollback.id,
            siteID: "site-one",
            status: .uncertain,
            problem: .init(code: .interruptedEffect, message: "inspect")
        )
        _ = try store.reconcile(
            siteID: "site-one",
            recordID: rollback.id,
            resolution: .confirmedApplied
        )
        #expect(try store.currentMutation(siteID: "site-one") == nil)
    }
}

private func waitForReview(
    service: QuasarService,
    siteID: String
) async throws -> QuasarPlanReview? {
    for _ in 0..<100 {
        if let review = try await service.pendingReview(id: siteID) { return review }
        try await Task.sleep(for: .milliseconds(10))
    }
    return nil
}
