import Foundation
import Testing
@testable import AbbeyQuasarKit

@Suite("Quasar filesystem and authorization")
struct QuasarSecurityTests {
    @Test func pathGuardRejectsTraversalAndBlockedComponents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let guarder = try QuasarPathGuard(root: root)
        #expect(throws: QuasarError.self) { try guarder.resolve("../escape") }
        #expect(throws: QuasarError.self) { try guarder.resolve("node_modules/pkg/index.js") }
        #expect(throws: QuasarError.self) { try guarder.resolve(".git/config") }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(throws: QuasarError.self) { try guarder.resolve("escape", permitMissingLeaf: false) }

        let blocked = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blocked.appendingPathComponent("config"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("innocent-alias"),
            withDestinationURL: blocked
        )
        #expect(throws: QuasarError.self) {
            try guarder.resolve("innocent-alias/config", permitMissingLeaf: false)
        }

        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("real-alias"),
            withDestinationURL: real
        )
        #expect(
            try guarder.resolve("real-alias/new.txt").path
                == guarder.resolve("real/new.txt").path
        )

        let nested = try guarder.resolve("app/page.tsx")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("page".utf8).write(to: nested)
        let listed = try guarder.list()
        #expect(listed == ["app/page.tsx"])
    }

    @Test func registryLockAndCrashRecoveryAreFailClosed() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let recovered = [Site(id: "recovered", name: "Recovered", slug: "recovered")]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recovered).write(to: home.appendingPathComponent("registry.json.tmp"), options: .atomic)
        let registry = try QuasarRegistry(home: home)
        #expect(await registry.list().map(\.id) == ["recovered"])
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("registry.json").path))
        #expect(throws: QuasarError.registryLocked) { _ = try QuasarRegistry(home: home) }
    }

    @Test func registryAllocatesUniqueSlugsAndPersists() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = try QuasarRegistry(home: home)
        let first = try await registry.reserve(name: "My Site", prompt: "one")
        let second = try await registry.reserve(name: "My Site", prompt: "two")
        #expect(first.slug == "my-site")
        #expect(second.slug == "my-site-2")
        #expect((try JSONDecoder().decode([Site].self, from: Data(contentsOf: home.appendingPathComponent("registry.json")))).count == 2)
    }

    @Test func corruptedRegistryIdentityPathAndPortFactsFailClosed() throws {
        for invalid in [
            [Site(id: "one", name: "Site", slug: "../escape")],
            [
                Site(id: "duplicate", name: "One", slug: "one", previewPort: 4_710),
                Site(id: "duplicate", name: "Two", slug: "two", previewPort: 4_711),
            ],
            [
                Site(id: "one", name: "One", slug: "one", previewPort: 4_710),
                Site(id: "two", name: "Two", slug: "two", previewPort: 4_710),
            ],
        ] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: home) }
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try JSONEncoder().encode(invalid).write(
                to: home.appendingPathComponent("registry.json"),
                options: .atomic
            )
            #expect(throws: QuasarError.self) { _ = try QuasarRegistry(home: home) }
        }
    }

    @Test func registryRejectsInvalidOrCollidingPreviewPorts() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = try QuasarRegistry(home: home)
        let first = try await registry.reserve(name: "One", prompt: "one")
        let second = try await registry.reserve(name: "Two", prompt: "two")
        try await registry.setPreviewPort(id: first.id, port: 4_710)
        await #expect(throws: QuasarError.self) {
            try await registry.setPreviewPort(id: second.id, port: 4_710)
        }
        await #expect(throws: QuasarError.self) {
            try await registry.setPreviewPort(id: second.id, port: 80)
        }
    }

    @Test func proposalRequiresDesktopAndExactRevalidation() async throws {
        let gate = QuasarProposalGate()
        let facts = QuasarAuthorizationFacts(guildID: "g", initiatorID: "owner", ownerAllowed: true, discordPermissionAllowed: true, guildOptedIn: true, quiet: false, remainingBudget: 1)
        let proposal = try await gate.propose(action: .edit, siteID: "s", summary: "edit", impact: "one file", rollback: "snapshot", facts: facts)
        await #expect(throws: QuasarError.self) { try await gate.approve(id: proposal.id, digest: proposal.digest, revalidated: facts, desktopConfirmed: false) }
        let approved = try await gate.approve(id: proposal.id, digest: proposal.digest, revalidated: facts, desktopConfirmed: true)
        #expect(approved.id == proposal.id)
    }

    @Test func previewLogsAreBoundedAndRedacted() {
        let lines = QuasarPreviewManager.lines(
            (0..<80).map {
                $0 == 79 ? "Authorization: Bearer bearer-secret" : "line-\($0)"
            }.joined(separator: "\n")
        )
        #expect(lines.count == 50)
        #expect(lines.last == "Authorization=<redacted>")
        #expect(!lines.joined().contains("bearer-secret"))
    }
}
