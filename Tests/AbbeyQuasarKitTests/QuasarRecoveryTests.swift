import Foundation
import Testing
@testable import AbbeyQuasarKit

@Suite("Quasar generation recovery")
struct QuasarRecoveryTests {
    @Test(arguments: ["registry.json", "registry.json.tmp"])
    func recoveryOnlyChangesGeneratingRecords(registryFile: String) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let idle = Site(name: "Idle", slug: "idle", previewPort: 4_710)
        let failed = Site(name: "Failed", slug: "failed", status: .error, lastError: "original error")
        let generating = Site(name: "Generating", slug: "generating", status: .generating)
        try JSONEncoder().encode([idle, failed, generating]).write(
            to: base.appendingPathComponent(registryFile), options: .atomic
        )
        let registry = try QuasarRegistry(home: base)
        #expect(await registry.site(id: idle.id) == idle)
        #expect(await registry.site(id: failed.id) == failed)
        #expect(await registry.site(id: generating.id)?.status == .error)
        let persisted = try JSONDecoder().decode(
            [Site].self, from: Data(contentsOf: base.appendingPathComponent("registry.json"))
        )
        #expect(persisted == (await registry.list()))
        _ = try await registry.beginEdit(id: generating.id, prompt: "fresh plan")
    }

    @Test func restartFromPendingApprovalRequiresFreshPlanningAndApproval() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let originalHome = base.appendingPathComponent("original")
        let recoveredHome = base.appendingPathComponent("recovered")
        let original = try QuasarService(home: originalHome, planner: recoveryPlanner)
        let site = try await original.create(name: "Recovery", prompt: "old plan")
        let oldPlan = try await recoveryPlan(service: original, siteID: site.id)
        let originalRecord = try await original.site(id: site.id)
        #expect(originalRecord.status == .generating)

        // A second writer must not reconcile the live writer's pending approval.
        #expect(throws: QuasarError.registryLocked) { _ = try QuasarRegistry(home: originalHome) }
        #expect(try await original.site(id: site.id) == originalRecord)

        // Snapshot the durable bytes at the crash boundary, without clean shutdown.
        // The reopened service has neither the old task nor its prepared payload.
        try FileManager.default.copyItem(at: originalHome, to: recoveredHome)
        let recovered = try QuasarService(home: recoveredHome, planner: recoveryPlanner)
        let interrupted = try await recovered.site(id: site.id)
        #expect(interrupted.status == .error)
        #expect(interrupted.lastError == "generation interrupted by restart; prepare and approve a new plan")
        #expect(interrupted.promptHistory == originalRecord.promptHistory)
        let persisted = try JSONDecoder().decode(
            [Site].self, from: Data(contentsOf: recoveredHome.appendingPathComponent("registry.json"))
        )
        #expect(persisted == [interrupted])
        #expect(try await recovered.pendingPlan(id: site.id) == nil)
        await #expect(throws: QuasarError.notFound) {
            _ = try await recovered.approve(id: site.id, planDigest: oldPlan.planDigest)
        }
        await #expect(throws: QuasarError.notFound) { try await recovered.reject(id: site.id) }

        let target = recoveredHome.appendingPathComponent("sites/recovery/recovery.txt")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        _ = try await recovered.edit(id: site.id, prompt: "fresh plan")
        let freshPlan = try await recoveryPlan(service: recovered, siteID: site.id)
        #expect(freshPlan.planDigest != oldPlan.planDigest)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        _ = try await recovered.approve(id: site.id, planDigest: freshPlan.planDigest)
        #expect(try String(contentsOf: target, encoding: .utf8) == "fresh plan")
        #expect(try await recovered.site(id: site.id).status == .idle)
        await original.shutdown()
        await recovered.shutdown()
    }

    @Test func serviceShutdownDiscardsPendingApprovalAndRejectsNewPlanning() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = try QuasarService(home: base, planner: recoveryPlanner)
        let site = try await service.create(name: "Shutdown", prompt: "pending")
        let plan = try await recoveryPlan(service: service, siteID: site.id)
        await service.shutdown()
        await service.shutdown()
        #expect(try await service.pendingPlan(id: site.id) == nil)
        #expect(try await service.site(id: site.id).status == .error)
        await #expect(throws: QuasarError.notFound) {
            _ = try await service.approve(id: site.id, planDigest: plan.planDigest)
        }
        await #expect(throws: QuasarError.self) { _ = try await service.edit(id: site.id, prompt: "new") }
        await #expect(throws: QuasarError.self) { _ = try await service.create(name: "New", prompt: "new") }
        #expect(await service.listSites().count == 1)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("sites/shutdown/recovery.txt").path))
    }

    @Test func previewAdmissionRemainsClosedAfterServiceAndManagerShutdown() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let launches = RecoveryCounter()
        let preview = QuasarPreviewManager(command: .init(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: { _ in launches.increment(); return ["30"] }
        ))
        let service = try QuasarService(home: base, planner: recoveryPlanner, preview: preview)
        let site = try await service.registry.reserve(name: "Stopped", prompt: "ready")
        try await service.registry.finish(id: site.id)
        await service.shutdown()
        await #expect(throws: QuasarError.processFailed("Quasar service is shut down")) {
            _ = try await service.startPreview(id: site.id)
        }
        #expect(await preview.start(siteID: site.id, siteRoot: base, port: 4_710).state == .stopped)
        #expect(launches.value == 0)
        #expect(try await service.site(id: site.id).previewPort == nil)
    }

    @Test(arguments: [false, true])
    func serviceShutdownInvalidatesSuspendedPreviewReadiness(ready: Bool) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let gate = RecoveryPlannerGate()
        let preview = QuasarPreviewManager(
            readinessAttempts: 1,
            command: .init(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: { _ in ["30"] }),
            readinessProbe: { _ in
                do { try await gate.suspend(); return ready }
                catch { return false }
            }
        )
        let service = try QuasarService(home: base, planner: recoveryPlanner, preview: preview)
        let site = try await service.registry.reserve(name: "Starting", prompt: "ready")
        try await service.registry.finish(id: site.id)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("sites/starting"), withIntermediateDirectories: true
        )
        let start = Task { try await service.startPreview(id: site.id) }
        let completion = RecoveryCompletion()
        Task { _ = await start.result; await completion.finish() }
        do {
            try await gate.waitUntilStarted()
            await service.shutdown()
            await gate.release()
            try await recoveryWait { await completion.finished }
            await #expect(throws: QuasarError.processFailed("Quasar service is shut down")) {
                _ = try await start.value
            }
            #expect(await preview.status(siteID: site.id).state == .stopped)
            #expect(try await service.site(id: site.id).previewPort == nil)
        } catch {
            await gate.release()
            await service.shutdown()
            throw error
        }
    }

    @Test func managerShutdownPreventsReplacementAfterSuspendedStop() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let launches = RecoveryCounter()
        let signals = RecoveryCounter()
        let live = QuasarProcessGroupSystem.live
        let preview = QuasarPreviewManager(
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: { _ in launches.increment(); return ["30"] }
            ),
            readinessProbe: { _ in true },
            processGroups: .init(
                processGroupID: live.processGroupID,
                currentProcessGroupID: live.currentProcessGroupID,
                signalGroup: { group, signal in
                    signals.increment()
                    return live.signalGroup(group, signal)
                },
                liveness: live.liveness
            )
        )
        do {
            let initial = await preview.start(siteID: "replacement", siteRoot: base, port: 4_710)
            try #require(initial.state == .running)
            let replacement = Task { await preview.start(siteID: "replacement", siteRoot: base, port: 4_710) }
            let completion = RecoveryCompletion()
            Task { _ = await replacement.value; await completion.finish() }
            try await recoveryWait { signals.value > 0 }
            await preview.shutdown()
            try await recoveryWait { await completion.finished }
            #expect(await replacement.value.state != .running)
            #expect(launches.value == 1)
        } catch {
            await preview.shutdown()
            throw error
        }
    }

    @Test func stopAllStillAllowsSubsequentPreviewStart() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let launches = RecoveryCounter()
        let preview = QuasarPreviewManager(
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: { _ in launches.increment(); return ["30"] }
            ),
            readinessProbe: { _ in true }
        )
        await preview.stopAll()
        let started = await preview.start(siteID: "reusable", siteRoot: base, port: 4_710)
        await preview.shutdown()
        #expect(started.state == .running)
        #expect(launches.value == 1)
    }

    @Test(arguments: [false, true])
    func shutdownInvalidatesLatePlannerCompletion(fails: Bool) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = try QuasarRegistry(home: base)
        let site = try await registry.reserve(name: "Late", prompt: "late")
        let root = base.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gate = RecoveryPlannerGate()
        let planner = QuasarPlanner(
            readPlan: { _, _ in .init(paths: []) },
            mutationPlan: { _, _ in
                try await gate.suspend()
                if fails { throw QuasarError.processFailed("late planner failure") }
                return .init(
                    summary: "late", operations: [.write(path: "late.txt", content: "late")],
                    idempotencyKey: "late"
                )
            }
        )
        let coordinator = QuasarGenerationCoordinator()
        let executor = QuasarMutationExecutor()
        try await coordinator.start(
            site: site, prompt: "late", siteRoot: root,
            registry: registry, planner: planner, executor: executor
        )
        try await gate.waitUntilStarted()
        let cancelledTasks = await coordinator.shutdown(registry: registry)
        await gate.release()
        #expect(cancelledTasks.count == 1)
        let interrupted = try #require(await registry.site(id: site.id))
        #expect(interrupted.status == .error)
        #expect(interrupted.lastError == "generation interrupted by shutdown; prepare and approve a new plan")

        // The planner ignores cancellation. Await the entire generation task,
        // not a sleep or just the planner callback, before checking for late writes.
        let completion = RecoveryCompletion()
        Task {
            for task in cancelledTasks { await task.value }
            await completion.finish()
        }
        try await recoveryWait { await completion.finished }
        #expect(await coordinator.pending(siteID: site.id) == nil)
        #expect(await coordinator.events(siteID: site.id, since: 0).events.isEmpty)
        #expect(await registry.site(id: site.id) == interrupted)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("late.txt").path))
        await #expect(throws: QuasarError.self) {
            try await coordinator.start(
                site: site, prompt: "new", siteRoot: root,
                registry: registry, planner: planner, executor: executor
            )
        }
    }
}

private let recoveryPlanner = QuasarPlanner(
    readPlan: { _, _ in .init(paths: []) },
    mutationPlan: { prompt, _ in
        .init(
            summary: prompt, operations: [.write(path: "recovery.txt", content: prompt)],
            idempotencyKey: prompt
        )
    }
)

private actor RecoveryPlannerGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var hasStarted = false
    private var released = false

    func suspend() async throws {
        hasStarted = true
        guard !released else { return }
        // Deliberately ignore caller cancellation, but never retain a continuation
        // forever if startup/assertions fail before the test can release it.
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            expire()
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async throws {
        try await recoveryWait { await self.hasStarted }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    private func expire() {
        continuation?.resume(throwing: QuasarError.processFailed("timed out waiting for test gate release"))
        continuation = nil
    }
}

private actor RecoveryCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}

private final class RecoveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

private func recoveryWait(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw QuasarError.processFailed("timed out waiting for recovery test progress")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func recoveryPlan(service: QuasarService, siteID: String) async throws -> QuasarMutationPreview {
    for _ in 0..<100 {
        if let plan = try await service.pendingPlan(id: siteID) { return plan }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw QuasarError.processFailed("timed out waiting for recovery plan")
}
