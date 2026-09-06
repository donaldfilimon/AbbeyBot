import Foundation
import Testing
@testable import AbbeyQuasarKit

@Suite("Quasar mutation executor")
struct QuasarMutationTests {
    @Test func appliesIdempotentlyAndCreatesRollbackSnapshot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let site = base.appendingPathComponent("site")
        let rollback = base.appendingPathComponent("rollback")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: site.appendingPathComponent("page.txt"))
        let executor = QuasarMutationExecutor()
        let plan = QuasarMutationPlan(summary: "replace", operations: [.write(path: "page.txt", content: "new")], idempotencyKey: "request-1")
        let first = try await executor.apply(plan, siteID: "site", to: site, rollbackRoot: rollback)
        let second = try await executor.apply(plan, siteID: "site", to: site, rollbackRoot: rollback)
        #expect(first == second)
        #expect(first.siteID == "site")
        #expect(try String(contentsOf: site.appendingPathComponent("page.txt"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: first.rollbackDirectory + "/files/page.txt"))
        let rollbackReceipt = try await executor.rollback(
            planDigest: first.planDigest,
            siteID: "site",
            siteRoot: site,
            rollbackRoot: rollback
        )
        #expect(rollbackReceipt.restoredPaths == ["page.txt"])
        #expect(try String(contentsOf: site.appendingPathComponent("page.txt"), encoding: .utf8) == "old")
    }

    @Test func rejectsIdempotencyKeyReusedForDifferentPlan() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let site = base.appendingPathComponent("site")
        let rollback = base.appendingPathComponent("rollback")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)

        let executor = QuasarMutationExecutor()
        let first = QuasarMutationPlan(
            summary: "first",
            operations: [.write(path: "first.txt", content: "first")],
            idempotencyKey: "shared-key"
        )
        let conflicting = QuasarMutationPlan(
            summary: "conflicting",
            operations: [.write(path: "second.txt", content: "second")],
            idempotencyKey: "shared-key"
        )

        _ = try await executor.apply(first, siteID: "site", to: site, rollbackRoot: rollback)
        await #expect(throws: QuasarError.proposalChanged) {
            _ = try await executor.apply(
                conflicting,
                siteID: "site",
                to: site,
                rollbackRoot: rollback
            )
        }
        #expect(!FileManager.default.fileExists(atPath: site.appendingPathComponent("second.txt").path))
    }

    @Test func rejectsDifferentSpellingsOfTheSameMutationTarget() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let site = base.appendingPathComponent("site")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)

        let executor = QuasarMutationExecutor()
        let plan = QuasarMutationPlan(
            summary: "duplicate destination",
            operations: [
                .write(path: "app/page.tsx", content: "first"),
                .write(path: "app//page.tsx", content: "second"),
            ],
            idempotencyKey: "duplicate-destination"
        )

        await #expect(throws: QuasarError.self) {
            _ = try await executor.validate(plan, siteID: "site", siteRoot: site)
        }
    }

    @Test func incompleteRollbackSnapshotCannotDeleteCurrentWork() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let site = base.appendingPathComponent("site")
        let rollback = base.appendingPathComponent("rollback")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let page = site.appendingPathComponent("page.txt")
        try Data("old".utf8).write(to: page)

        let executor = QuasarMutationExecutor()
        let plan = QuasarMutationPlan(
            summary: "replace",
            operations: [.write(path: "page.txt", content: "new")],
            idempotencyKey: "incomplete-rollback"
        )
        let receipt = try await executor.apply(
            plan,
            siteID: "site",
            to: site,
            rollbackRoot: rollback
        )
        try FileManager.default.removeItem(
            atPath: receipt.rollbackDirectory + "/files/page.txt"
        )
        try Data("newer-unrelated-work".utf8).write(to: page, options: .atomic)

        await #expect(throws: QuasarError.self) {
            _ = try await executor.rollback(
                planDigest: receipt.planDigest,
                siteID: "site",
                siteRoot: site,
                rollbackRoot: rollback
            )
        }
        #expect(try String(contentsOf: page, encoding: .utf8) == "newer-unrelated-work")
    }

    @Test func unexpectedBackupForOriginallyAbsentPathCannotDeleteCurrentWork() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let site = base.appendingPathComponent("site")
        let rollback = base.appendingPathComponent("rollback")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let page = site.appendingPathComponent("page.txt")

        let executor = QuasarMutationExecutor()
        let plan = QuasarMutationPlan(
            summary: "create",
            operations: [.write(path: "page.txt", content: "generated")],
            idempotencyKey: "unexpected-absent-backup"
        )
        let receipt = try await executor.apply(
            plan,
            siteID: "site",
            to: site,
            rollbackRoot: rollback
        )
        let unexpectedBackup = URL(fileURLWithPath: receipt.rollbackDirectory)
            .appendingPathComponent("files/page.txt")
        try FileManager.default.createDirectory(
            at: unexpectedBackup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("unexpected".utf8).write(to: unexpectedBackup, options: .atomic)
        try Data("newer-unrelated-work".utf8).write(to: page, options: .atomic)

        await #expect(throws: QuasarError.self) {
            _ = try await executor.rollback(
                planDigest: receipt.planDigest,
                siteID: "site",
                siteRoot: site,
                rollbackRoot: rollback
            )
        }
        #expect(try String(contentsOf: page, encoding: .utf8) == "newer-unrelated-work")
    }

    @Test func rollbackRefusesToOverwriteWorkChangedAfterTheApprovedMutation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let site = base.appendingPathComponent("site")
        let rollback = base.appendingPathComponent("rollback")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let page = site.appendingPathComponent("page.txt")
        try Data("before".utf8).write(to: page)
        let executor = QuasarMutationExecutor()
        let receipt = try await executor.apply(
            .init(
                summary: "replace",
                operations: [.write(path: "page.txt", content: "approved")],
                idempotencyKey: "postimage"
            ),
            siteID: "site",
            to: site,
            rollbackRoot: rollback
        )
        try Data("operator work".utf8).write(to: page, options: .atomic)

        await #expect(throws: QuasarError.proposalChanged) {
            _ = try await executor.rollback(
                planDigest: receipt.planDigest,
                siteID: "site",
                siteRoot: site,
                rollbackRoot: rollback
            )
        }
        #expect(try String(contentsOf: page, encoding: .utf8) == "operator work")
    }
}
