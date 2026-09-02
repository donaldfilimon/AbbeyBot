import AbbeyCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
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

    @Test func previewStopEscalatesWhenGracefulSignalsAreIgnored() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let processMarker = base.appendingPathComponent("processes")
        let activity = base.appendingPathComponent("activity")
        var recordedProcessIDs: [Int32] = []
        defer {
            terminateExactProcessIDs(recordedProcessIDs + (readRecordedProcessIDs(at: processMarker) ?? []))
        }
        let preview = QuasarPreviewManager(
            readinessAttempts: 100,
            pollInterval: .milliseconds(10),
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: { _ in
                    [
                        "-c",
                        """
                        trap '' TERM INT
                        parent=$$
                        (
                          trap '' TERM INT
                          while :; do printf 'descendant\\n' >> "$2"; sleep 0.02; done
                        ) &
                        descendant=$!
                        printf '%s %s\\n' "$parent" "$descendant" > "$1"
                        while :; do printf 'leader\\n' >> "$2"; sleep 0.02; done
                        """,
                        "quasar-preview",
                        processMarker.path,
                        activity.path,
                    ]
                }
            ),
            readinessProbe: { _ in
                readRecordedProcessIDs(at: processMarker) != nil
            }
        )

        let started = await preview.start(siteID: "forced-stop", siteRoot: base, port: 4_710)
        #expect(started.state == .running)
        recordedProcessIDs = try #require(await waitForRecordedProcessIDs(at: processMarker))
        #expect(recordedProcessIDs.count == 2)
        let leaderPID = recordedProcessIDs[0]
        let descendantPID = recordedProcessIDs[1]
        #expect(leaderPID != descendantPID)
        #expect(processGroupID(of: leaderPID) == leaderPID)
        #expect(processGroupID(of: descendantPID) == leaderPID)

        #expect(await preview.stop(siteID: "forced-stop"))
        #if canImport(Darwin)
        let leaderWasAbsentWhenStopReturned = !exactProcessExists(leaderPID)
        let descendantWasAbsentWhenStopReturned = !exactProcessExists(descendantPID)
        #endif
        let leaderExited = await waitForExactProcessExit(leaderPID)
        let descendantExited = await waitForExactProcessExit(descendantPID)
        let activityAfterStop = try Data(contentsOf: activity)
        try await Task.sleep(for: .milliseconds(250))
        let activityAfterObservation = try Data(contentsOf: activity)

        terminateExactProcessIDs(recordedProcessIDs)
        let leaderCleanupSucceeded = await waitForExactProcessExit(leaderPID)
        let descendantCleanupSucceeded = await waitForExactProcessExit(descendantPID)
        let cleanupSucceeded = leaderCleanupSucceeded && descendantCleanupSucceeded
        #expect(cleanupSucceeded, "exact-PID test cleanup did not reap both recorded processes")
        recordedProcessIDs.removeAll()
        try? FileManager.default.removeItem(at: processMarker)

        #expect(leaderExited, "preview leader \(leaderPID) survived stop")
        #expect(descendantExited, "preview descendant \(descendantPID) survived stop")
        #if canImport(Darwin)
        #expect(leaderWasAbsentWhenStopReturned, "preview leader still existed when stop returned")
        #expect(descendantWasAbsentWhenStopReturned, "preview descendant still existed when stop returned")
        #endif
        #expect(
            activityAfterObservation == activityAfterStop,
            "preview activity continued after stop returned"
        )
        #expect(await preview.status(siteID: "forced-stop").state == .stopped)
        await preview.stopAll()
    }

    @Test func previewStopUsesCooperativeTermAndCanBeRepeatedAfterAbsence() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let processMarker = base.appendingPathComponent("process")
        let termMarker = base.appendingPathComponent("term")
        var processID: Int32?
        defer { if let processID { terminateExactProcessIDs([processID]) } }
        let preview = QuasarPreviewManager(
            readinessAttempts: 100,
            pollInterval: .milliseconds(10),
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: { _ in
                    [
                        "-c",
                        "trap 'printf term > \"$2\"; exit 0' TERM; printf '%s\\n' \"$$\" > \"$1\"; while :; do sleep 0.05; done",
                        "quasar-preview",
                        processMarker.path,
                        termMarker.path,
                    ]
                }
            ),
            readinessProbe: { _ in readRecordedProcessID(at: processMarker) != nil }
        )

        #expect(await preview.start(siteID: "cooperative", siteRoot: base, port: 4_711).state == .running)
        guard let recordedProcessID = await waitForRecordedProcessID(at: processMarker) else {
            throw QuasarError.processFailed("cooperative preview did not record its process ID")
        }
        processID = recordedProcessID
        #expect(await preview.stop(siteID: "cooperative"))
        #expect(FileManager.default.fileExists(atPath: termMarker.path))
        #expect(await waitForExactProcessExit(recordedProcessID))
        #expect(await preview.stop(siteID: "cooperative"))
        #expect(await preview.status(siteID: "cooperative").state == .stopped)
        processID = nil
    }

    @Test func failedStartupKillsDescendantAfterLeaderExits() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let processMarker = base.appendingPathComponent("processes")
        var recordedProcessIDs: [Int32] = []
        defer {
            terminateExactProcessIDs(recordedProcessIDs + (readRecordedProcessIDs(at: processMarker) ?? []))
        }
        let preview = QuasarPreviewManager(
            readinessAttempts: 100,
            pollInterval: .milliseconds(10),
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: { _ in
                    [
                        "-c",
                        "(trap '' TERM INT; while :; do sleep 0.05; done) & child=$!; printf '%s %s\\n' \"$$\" \"$child\" > \"$1\"; sleep 0.2; exit 0",
                        "quasar-preview",
                        processMarker.path,
                    ]
                }
            ),
            readinessProbe: { _ in false }
        )

        let status = await preview.start(siteID: "leader-exit", siteRoot: base, port: 4_712)
        #expect(status.state == .crashed)
        recordedProcessIDs = try #require(await waitForRecordedProcessIDs(at: processMarker))
        let leaderExited = await waitForExactProcessExit(recordedProcessIDs[0])
        let descendantExited = await waitForExactProcessExit(recordedProcessIDs[1])
        #expect(leaderExited)
        #expect(descendantExited, "descendant survived startup-failure group cleanup")
        recordedProcessIDs.removeAll()
    }

    @Test func previewStartupRejectsInvalidAndSelfProcessGroups() async throws {
        let cases: [(String, @Sendable (Int32) -> Int32?)] = [
            ("missing", { _ in nil }),
            ("non-leader", { $0 + 1 }),
            ("self", { _ in currentProcessGroupID() }),
        ]
        for (name, groupID) in cases {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let processMarker = base.appendingPathComponent("process")
            let processGroups = QuasarProcessGroupSystem(
                processGroupID: groupID,
                currentProcessGroupID: { currentProcessGroupID() },
                signalGroup: { _, _ in .failed },
                liveness: { _ in .unverifiable }
            )
            let preview = QuasarPreviewManager(
                readinessAttempts: 1,
                pollInterval: .milliseconds(1),
                command: .init(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: { _ in
                        ["-c", "printf '%s\\n' \"$$\" > \"$1\"; exec sleep 30", "quasar-preview", processMarker.path]
                    }
                ),
                readinessProbe: { _ in true },
                processGroups: processGroups
            )

            let status = await preview.start(siteID: name, siteRoot: base, port: 4_713)
            #expect(status.state == .crashed)
            #expect(status.logTail.contains { $0.contains("private owned process group") })
            if let processID = await waitForRecordedProcessID(at: processMarker) {
                #expect(await waitForExactProcessExit(processID), "invalid-group leader survived fail-closed cleanup")
                terminateExactProcessIDs([processID])
            }
        }
    }

    @Test func previewStartupRejectsLeaderThatExitsDuringOwnershipValidation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let processGroups = QuasarProcessGroupSystem(
            processGroupID: { processID in
                Thread.sleep(forTimeInterval: 0.1)
                return processID
            },
            currentProcessGroupID: { currentProcessGroupID() },
            signalGroup: { _, _ in .failed },
            liveness: { _ in .unverifiable }
        )
        let preview = QuasarPreviewManager(
            readinessAttempts: 1,
            pollInterval: .milliseconds(1),
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: { _ in ["-c", "exit 0", "quasar-preview"] }
            ),
            readinessProbe: { _ in true },
            processGroups: processGroups
        )

        let status = await preview.start(siteID: "early-exit", siteRoot: base, port: 4_717)
        #expect(status.state == .crashed)
        #expect(status.logTail.contains { $0.contains("private owned process group") })
    }

    @Test func linuxProcfsGroupLivenessFailsClosedForMissingAndMalformedState() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(QuasarProcessGroupSystem.linuxLiveness(groupID: 4_242, procRoot: missing) == .unverifiable)

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let stat = base.appendingPathComponent("123/stat")
        try FileManager.default.createDirectory(at: stat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("malformed".utf8).write(to: stat, options: .atomic)
        #expect(QuasarProcessGroupSystem.linuxLiveness(groupID: 4_242, procRoot: base) == .unverifiable)

        try Data("123 (worker name) Z 1 4242 0 0".utf8).write(to: stat, options: .atomic)
        #expect(QuasarProcessGroupSystem.linuxLiveness(groupID: 4_242, procRoot: base) == .zombieOnly)
        try Data("123 (worker name) S 1 4242 0 0".utf8).write(to: stat, options: .atomic)
        #expect(QuasarProcessGroupSystem.linuxLiveness(groupID: 4_242, procRoot: base) == .live)
    }

    @Test func replacementRefusesWhenPriorGroupExitCannotBeProven() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let processMarker = base.appendingPathComponent("process")
        var processID: Int32?
        defer { if let processID { terminateExactProcessIDs([processID]) } }
        let processGroups = QuasarProcessGroupSystem(
            processGroupID: { $0 },
            currentProcessGroupID: { currentProcessGroupID() },
            signalGroup: { _, _ in .delivered },
            liveness: { _ in .unverifiable }
        )
        let preview = QuasarPreviewManager(
            readinessAttempts: 100,
            pollInterval: .milliseconds(1),
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: { _ in
                    ["-c", "printf '%s\\n' \"$$\" > \"$1\"; exec sleep 30", "quasar-preview", processMarker.path]
                }
            ),
            readinessProbe: { _ in readRecordedProcessID(at: processMarker) != nil },
            processGroups: processGroups
        )

        #expect(await preview.start(siteID: "replacement", siteRoot: base, port: 4_714).state == .running)
        guard let recordedProcessID = await waitForRecordedProcessID(at: processMarker) else {
            throw QuasarError.processFailed("replacement preview did not record its process ID")
        }
        processID = recordedProcessID
        let replacement = await preview.start(siteID: "replacement", siteRoot: base, port: 4_715)
        #expect(replacement.state == .crashed)
        #expect(replacement.logTail == ["Prior preview process did not stop; replacement was not launched."])
        #expect(exactProcessExists(recordedProcessID))
        terminateExactProcessIDs([recordedProcessID])
        #expect(await waitForExactProcessExit(recordedProcessID))
        processID = nil
    }

    #if canImport(Darwin)
    @Test func darwinZombieOnlyLivenessFailsClosed() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let processMarker = base.appendingPathComponent("process")
        var processID: Int32?
        defer { if let processID { terminateExactProcessIDs([processID]) } }
        let processGroups = QuasarProcessGroupSystem(
            processGroupID: { $0 },
            currentProcessGroupID: { currentProcessGroupID() },
            signalGroup: { _, _ in .failed },
            liveness: { _ in .zombieOnly }
        )
        let preview = QuasarPreviewManager(
            readinessAttempts: 100,
            pollInterval: .milliseconds(1),
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: { _ in
                    ["-c", "printf '%s\\n' \"$$\" > \"$1\"; exec sleep 30", "quasar-preview", processMarker.path]
                }
            ),
            readinessProbe: { _ in readRecordedProcessID(at: processMarker) != nil },
            processGroups: processGroups
        )

        #expect(await preview.start(siteID: "darwin-zombie", siteRoot: base, port: 4_716).state == .running)
        guard let recordedProcessID = await waitForRecordedProcessID(at: processMarker) else {
            throw QuasarError.processFailed("Darwin zombie probe did not record its process ID")
        }
        processID = recordedProcessID
        #expect(exactProcessExists(recordedProcessID))
        #expect(!(await preview.stop(siteID: "darwin-zombie")))
        #expect(await preview.status(siteID: "darwin-zombie").state == .crashed)
        #expect(exactProcessExists(recordedProcessID))
        terminateExactProcessIDs([recordedProcessID])
        #expect(await waitForExactProcessExit(recordedProcessID))
        processID = nil
    }
    #endif

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

private func readRecordedProcessID(at marker: URL) -> Int32? {
    guard
        let value = try? String(contentsOf: marker, encoding: .utf8),
        value.hasSuffix("\n"),
        let processID = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
        processID > 1
    else { return nil }
    return processID
}

private func waitForRecordedProcessID(at marker: URL) async -> Int32? {
    for _ in 0..<200 {
        if let processID = readRecordedProcessID(at: marker) { return processID }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

private func readRecordedProcessIDs(at marker: URL) -> [Int32]? {
    guard
        let value = try? String(contentsOf: marker, encoding: .utf8),
        value.hasSuffix("\n")
    else { return nil }
    let processIDs = value.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    guard processIDs.count == 2, processIDs.allSatisfy({ $0 > 1 }) else { return nil }
    return processIDs
}

private func waitForRecordedProcessIDs(at marker: URL) async -> [Int32]? {
    for _ in 0..<200 {
        if let processIDs = readRecordedProcessIDs(at: marker) { return processIDs }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

private func processGroupID(of processID: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.getpgid(processID)
    #elseif canImport(Glibc)
    Glibc.getpgid(processID)
    #elseif canImport(Musl)
    Musl.getpgid(processID)
    #else
    -1
    #endif
}

private func currentProcessGroupID() -> Int32 {
    #if canImport(Darwin)
    Darwin.getpgrp()
    #elseif canImport(Glibc)
    Glibc.getpgrp()
    #elseif canImport(Musl)
    Musl.getpgrp()
    #else
    -1
    #endif
}

private func exactProcessExists(_ processID: Int32) -> Bool {
    #if canImport(Darwin)
    if Darwin.kill(processID, 0) == 0 { return true }
    #elseif canImport(Glibc)
    if Glibc.kill(processID, 0) == 0 { return true }
    #elseif canImport(Musl)
    if Musl.kill(processID, 0) == 0 { return true }
    #else
    return false
    #endif
    return errno == EPERM
}

private func waitForExactProcessExit(_ processID: Int32) async -> Bool {
    for _ in 0..<300 {
        guard exactProcessExists(processID) else { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return !exactProcessExists(processID)
}

private func terminateExactProcessIDs(_ processIDs: [Int32]) {
    for processID in Set(processIDs) where processID > 1 {
        #if canImport(Darwin)
        _ = Darwin.kill(processID, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(processID, SIGKILL)
        #elseif canImport(Musl)
        _ = Musl.kill(processID, SIGKILL)
        #endif
    }
}
