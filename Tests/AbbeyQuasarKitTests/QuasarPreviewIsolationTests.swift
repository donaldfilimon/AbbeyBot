import Foundation
import Testing
@testable import AbbeyQuasarKit

@Suite("Quasar preview isolation")
struct QuasarPreviewIsolationTests {
    @Test func dependencyFingerprintModelsReviewedPostMutationInputs() throws {
        let root = try fixtureSite()
        defer { try? FileManager.default.removeItem(at: root) }

        let current = try QuasarDependencyFingerprint.capture(siteRoot: root)
        let reviewed = try QuasarDependencyFingerprint.capture(
            siteRoot: root,
            applying: [
                .write(path: "package.json", content: "{\"scripts\":{},\"dependencies\":{\"next\":\"15.5.23\"}}\n")
            ]
        )

        #expect(current != reviewed)
        #expect(reviewed.bunLockSHA256 == current.bunLockSHA256)
        #expect(reviewed.packageJSONSHA256.count == 64)
        #expect(throws: QuasarError.self) {
            _ = try QuasarDependencyFingerprint.capture(
                siteRoot: root,
                applying: [.remove(path: "bun.lock")]
            )
        }
    }

    @Test func preparationRunsFrozenInstallWithoutScriptsInCredentialFreeLocalEnvironment() async throws {
        let root = try fixtureSite()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = root.appendingPathComponent("bun-invocation.txt")
        let fakeBun = root.appendingPathComponent("fake-bun.sh")
        let script = """
            #!/bin/sh
            {
              printf 'args=%s\\n' "$*"
              printf 'home=%s\\n' "$HOME"
              printf 'tmp=%s\\n' "$TMPDIR"
              printf 'cache=%s\\n' "$BUN_INSTALL_CACHE_DIR"
              printf 'token=%s\\n' "${ABBEY_API_TOKEN-unset}"
            } > "\(recorder.path)"
            mkdir -p node_modules/next/dist/bin
            printf 'entry' > node_modules/next/dist/bin/next
            """
        try Data(script.utf8).write(to: fakeBun)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeBun.path)
        let reviewed = try QuasarDependencyFingerprint.capture(siteRoot: root)
        let preparer = QuasarDependencyPreparer(
            bunExecutableURL: fakeBun,
            timeout: .seconds(5),
            inheritedEnvironment: [
                "PATH": "/usr/bin:/bin",
                "ABBEY_API_TOKEN": "must-not-leak",
            ]
        )

        let receipt = try await preparer.prepare(
            siteID: "site-one",
            generation: "generation-one",
            siteRoot: root,
            reviewedFingerprint: reviewed
        )
        let invocation = try String(contentsOf: recorder, encoding: .utf8)

        #expect(invocation.contains("args=install --frozen-lockfile --ignore-scripts"))
        #expect(invocation.contains("token=unset"))
        #expect(invocation.contains("home=\(root.path)/.quasar-runtime/home"))
        #expect(invocation.contains("tmp=\(root.path)/.quasar-runtime/tmp"))
        #expect(invocation.contains("cache=\(root.path)/.quasar-runtime/cache"))
        #expect(receipt.siteID == "site-one")
        #expect(receipt.generation == "generation-one")
        #expect(receipt.fingerprint == reviewed)
        #expect(receipt.nextEntryPoint == "node_modules/next/dist/bin/next")
    }

    @Test func preparationRejectsInputsChangedAfterReviewBeforeLaunchingBun() async throws {
        let root = try fixtureSite()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("launched")
        let fakeBun = root.appendingPathComponent("fake-bun.sh")
        try Data("#!/bin/sh\ntouch \"\(marker.path)\"\n".utf8).write(to: fakeBun)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeBun.path)
        let reviewed = try QuasarDependencyFingerprint.capture(siteRoot: root)
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("bun.lock"))
        let preparer = QuasarDependencyPreparer(bunExecutableURL: fakeBun, timeout: .seconds(5))

        await #expect(throws: QuasarError.proposalChanged) {
            _ = try await preparer.prepare(
                siteID: "site-one",
                generation: "generation-one",
                siteRoot: root,
                reviewedFingerprint: reviewed
            )
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func preparationRejectsRuntimeDirectorySymlink() async throws {
        let root = try fixtureSite()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".quasar-runtime"),
            withDestinationURL: outside
        )
        let reviewed = try QuasarDependencyFingerprint.capture(siteRoot: root)
        let preparer = QuasarDependencyPreparer(
            bunExecutableURL: root.appendingPathComponent("never-launched"),
            timeout: .seconds(5)
        )

        await #expect(throws: QuasarError.self) {
            _ = try await preparer.prepare(
                siteID: "site-one",
                generation: "generation-one",
                siteRoot: root,
                reviewedFingerprint: reviewed
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func ticketIsSingleUseHostBoundAndExchangesForSecureCookie() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let access = QuasarPreviewAccessController(previewDomain: "preview.xfoss.dev")
        await access.activate(
            .init(siteID: "site-one", generation: "generation-one", port: 4_710)
        )
        let ticket = try await access.issue(siteID: "site-one", generation: "generation-one", now: now)
        let token = try #require(URLComponents(string: ticket.url)?.queryItems?.first(where: { $0.name == "ticket" })?.value)

        await #expect(throws: QuasarError.self) {
            _ = try await access.redeem(ticket: token, host: "other.preview.xfoss.dev", now: now)
        }

        let replacement = try await access.issue(siteID: "site-one", generation: "generation-one", now: now)
        let replacementToken = try #require(URLComponents(string: replacement.url)?.queryItems?.first?.value)
        let grant = try await access.redeem(
            ticket: replacementToken,
            host: "site-one.preview.xfoss.dev",
            now: now
        )

        #expect(grant.redirectURL == "https://site-one.preview.xfoss.dev/")
        #expect(grant.setCookie.contains("__Host-abbey-quasar-preview="))
        #expect(grant.setCookie.contains("Secure"))
        #expect(grant.setCookie.contains("HttpOnly"))
        #expect(!grant.setCookie.contains("Domain="))
        #expect(grant.expiresAt == now.addingTimeInterval(900))
        await #expect(throws: QuasarError.self) {
            _ = try await access.redeem(
                ticket: replacementToken,
                host: "site-one.preview.xfoss.dev",
                now: now
            )
        }

        let authorization = try await access.authorize(
            host: "site-one.preview.xfoss.dev",
            cookieHeader: grant.setCookie.components(separatedBy: ";")[0],
            now: now.addingTimeInterval(899)
        )
        #expect(authorization.upstream == "127.0.0.1:4710")
        #expect(authorization.siteID == "site-one")
        #expect(authorization.generation == "generation-one")
    }

    @Test func restartRetiresEarlierGenerationTicketsAndCookies() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let access = QuasarPreviewAccessController(previewDomain: "preview.xfoss.dev")
        await access.activate(.init(siteID: "site-one", generation: "one", port: 4_710))
        let firstTicket = try await access.issue(siteID: "site-one", generation: "one", now: now)
        let token = try #require(URLComponents(string: firstTicket.url)?.queryItems?.first?.value)
        let grant = try await access.redeem(ticket: token, host: "site-one.preview.xfoss.dev", now: now)

        await access.activate(.init(siteID: "site-one", generation: "two", port: 4_711))

        await #expect(throws: QuasarError.self) {
            _ = try await access.authorize(
                host: "site-one.preview.xfoss.dev",
                cookieHeader: grant.setCookie.components(separatedBy: ";")[0],
                now: now.addingTimeInterval(1)
            )
        }
        await #expect(throws: QuasarError.self) {
            _ = try await access.issue(siteID: "site-one", generation: "one", now: now)
        }
    }

    @Test func startingAnotherSiteStopsTheOnlyActivePreview() async throws {
        let firstRoot = try fixtureSite()
        let secondRoot = try fixtureSite()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let manager = QuasarPreviewManager(
            readinessAttempts: 2,
            pollInterval: .milliseconds(10),
            command: .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: { _ in ["sleep", "30"] }
            ),
            readinessProbe: { _ in true }
        )

        #expect(await manager.start(
            siteID: "first",
            generation: "generation-one",
            siteRoot: firstRoot,
            port: 4_710
        ).state == .running)
        #expect(await manager.start(
            siteID: "second",
            generation: "generation-two",
            siteRoot: secondRoot,
            port: 4_711
        ).state == .running)

        #expect(await manager.status(siteID: "first").state == .stopped)
        #expect(await manager.activePreview(siteID: "first") == nil)
        #expect(await manager.activePreview(siteID: "second") == .init(
            siteID: "second",
            generation: "generation-two",
            port: 4_711
        ))
        await manager.stopAll()
    }

    @Test func simultaneousStartsDoNotRetireAnAdmittedPreview() async throws {
        let firstRoot = try fixtureSite(), secondRoot = try fixtureSite()
        defer { try? FileManager.default.removeItem(at: firstRoot); try? FileManager.default.removeItem(at: secondRoot) }
        let gate = PreviewReadinessGate()
        let manager = QuasarPreviewManager(readinessAttempts: 2, pollInterval: .milliseconds(10),
            command: .init(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: { _ in ["sleep", "30"] }),
            readinessProbe: { url in if url.port == 4710 { await gate.pause() }; return true })
        let first = Task { await manager.start(siteID: "first", generation: "first", siteRoot: firstRoot, port: 4710) }
        await gate.waitUntilPaused()
        let second = await manager.start(siteID: "second", generation: "second", siteRoot: secondRoot, port: 4711)
        await gate.resume()
        let firstResult = await first.value
        #expect(firstResult.state == .running)
        #expect(second.state == .crashed)
        #expect(await manager.activePreview(siteID: "second") == nil)
        await manager.shutdown()
    }

    private func fixtureSite() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"dependencies\":{\"next\":\"15.5.23\"}}\n".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        try Data("lockfile-v1\n".utf8).write(to: root.appendingPathComponent("bun.lock"))
        return root
    }
}

private actor PreviewReadinessGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation = $0; for waiter in waiters { waiter.resume() }; waiters = [] }
    }
    func waitUntilPaused() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
