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

@Suite("Quasar preview process groups")
struct QuasarPreviewProcessGroupTests {
    @Test func supervisorLossProbeInvalidatesOwnershipWhileNumericGroupRemainsLive() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning { terminateExactProcessIDs([process.processIdentifier]) }
            process.waitUntilExit()
        }
        let probes = SupervisorLossReuseProbe()
        let processID = process.processIdentifier
        #expect(probes.validate(processID) == processID)
        #expect(probes.signal(processID, SIGTERM) == .delivered)
        #expect(probes.validate(processID) == nil)
        #expect(probes.liveness(processID) == .live)
        #expect(probes.validate(processID) == nil)
        #expect(probes.signals == [SIGTERM])
    }

    @Test func onlyGroupAbsenceProvesExit() {
        #expect(QuasarProcessGroupLiveness.absent.satisfiesExitProof)
        #expect(!QuasarProcessGroupLiveness.zombieOnly.satisfiesExitProof)
        #expect(!QuasarProcessGroupLiveness.live.satisfiesExitProof)
        #expect(!QuasarProcessGroupLiveness.unverifiable.satisfiesExitProof)
    }

    @Test func supervisorLossNeverAuthorizesSignalFromReusedNumericGroup() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let firstMarker = base.appendingPathComponent("first-process")
        let replacementMarker = base.appendingPathComponent("replacement-process")
        let probes = SupervisorLossReuseProbe()
        var commandProcessID: Int32?
        defer {
            terminateExactProcessIDs(
                probes.supervisorProcessIDs
                    + [commandProcessID, readRecordedProcessID(at: replacementMarker)]
                    .compactMap { $0 }
            )
        }
        let processGroups = QuasarProcessGroupSystem(
            processGroupID: probes.validate,
            currentProcessGroupID: { currentProcessGroupID() },
            signalGroup: probes.signal,
            liveness: probes.liveness
        )
        let preview = QuasarPreviewManager(
            readinessAttempts: 100,
            pollInterval: .milliseconds(1),
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: { port in
                    let marker = port == 4_721 ? firstMarker : replacementMarker
                    return [
                        "-c",
                        "printf '%s\\n' \"$$\" > \"$1\"; exec sleep 30",
                        "quasar-preview",
                        marker.path,
                    ]
                }
            ),
            readinessProbe: { _ in readRecordedProcessID(at: firstMarker) != nil },
            processGroups: processGroups
        )

        #expect(await preview.start(siteID: "lost-anchor", siteRoot: base, port: 4_721).state == .running)
        guard let firstCommandProcessID = await waitForRecordedProcessID(at: firstMarker) else {
            throw QuasarError.processFailed("lost-anchor preview did not record its process ID")
        }
        commandProcessID = firstCommandProcessID

        #expect(
            !(await preview.stop(siteID: "lost-anchor")),
            "losing the supervisor while its numeric PGID remains live must fail closed"
        )
        #expect(
            probes.signals == [SIGTERM],
            "a stable live or recycled numeric PGID authorized a later signal after supervisor loss"
        )
        #expect(await preview.status(siteID: "lost-anchor").state == .crashed)

        let replacement = await preview.start(siteID: "lost-anchor", siteRoot: base, port: 4_722)
        #expect(replacement.state == .crashed)
        #expect(replacement.logTail == ["Prior preview process did not stop; replacement was not launched."])
        #expect(!FileManager.default.fileExists(atPath: replacementMarker.path))
        #expect(probes.signals == [SIGTERM])

        if let commandProcessID {
            terminateExactProcessIDs([commandProcessID])
            #expect(await waitForExactProcessExit(commandProcessID))
        }
        commandProcessID = nil
    }

    @Test func previewStopEscalatesWhenGracefulSignalsAreIgnored() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let processMarker = base.appendingPathComponent("processes")
        let activity = base.appendingPathComponent("activity")
        var recordedProcessIDs: [Int32] = []
        var supervisorProcessID: Int32?
        defer {
            terminateExactProcessIDs(
                recordedProcessIDs
                    + (readRecordedProcessIDs(at: processMarker) ?? [])
                    + [supervisorProcessID].compactMap { $0 }
            )
        }
        let signals = LiveProcessGroupSignalRecorder()
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
            },
            processGroups: liveProcessGroups(recording: signals)
        )

        let started = await preview.start(siteID: "forced-stop", siteRoot: base, port: 4_710)
        #expect(started.state == .running)
        recordedProcessIDs = try #require(await waitForRecordedProcessIDs(at: processMarker))
        #expect(recordedProcessIDs.count == 2)
        let leaderPID = recordedProcessIDs[0]
        let descendantPID = recordedProcessIDs[1]
        #expect(leaderPID != descendantPID)
        let ownedGroupID = processGroupID(of: leaderPID)
        supervisorProcessID = ownedGroupID
        #expect(ownedGroupID > 1)
        #expect(ownedGroupID != currentProcessGroupID())
        #expect(processGroupID(of: ownedGroupID) == ownedGroupID)
        #expect(processGroupID(of: descendantPID) == ownedGroupID)

        #expect(await preview.stop(siteID: "forced-stop"))
        #if canImport(Darwin)
        let supervisorWasAbsentWhenStopReturned = !exactProcessExists(ownedGroupID)
        let leaderWasAbsentWhenStopReturned = !exactProcessExists(leaderPID)
        let descendantWasAbsentWhenStopReturned = !exactProcessExists(descendantPID)
        #endif
        let leaderExited = await waitForExactProcessExit(leaderPID)
        let descendantExited = await waitForExactProcessExit(descendantPID)
        let activityAfterStop = try Data(contentsOf: activity)
        try await Task.sleep(for: .milliseconds(250))
        let activityAfterObservation = try Data(contentsOf: activity)

        terminateExactProcessIDs(recordedProcessIDs + [ownedGroupID])
        let supervisorCleanupSucceeded = await waitForExactProcessExit(ownedGroupID)
        let leaderCleanupSucceeded = await waitForExactProcessExit(leaderPID)
        let descendantCleanupSucceeded = await waitForExactProcessExit(descendantPID)
        let cleanupSucceeded = supervisorCleanupSucceeded && leaderCleanupSucceeded && descendantCleanupSucceeded
        #expect(cleanupSucceeded, "exact-PID test cleanup did not reap the supervisor and both command processes")
        recordedProcessIDs.removeAll()
        supervisorProcessID = nil
        try? FileManager.default.removeItem(at: processMarker)

        #expect(leaderExited, "preview leader \(leaderPID) survived stop")
        #expect(descendantExited, "preview descendant \(descendantPID) survived stop")
        #if canImport(Darwin)
        #expect(supervisorWasAbsentWhenStopReturned, "preview supervisor still existed when stop returned")
        #expect(leaderWasAbsentWhenStopReturned, "preview leader still existed when stop returned")
        #expect(descendantWasAbsentWhenStopReturned, "preview descendant still existed when stop returned")
        #endif
        #expect(
            activityAfterObservation == activityAfterStop,
            "preview activity continued after stop returned"
        )
        #expect(signals.snapshot() == [SIGTERM, SIGINT, SIGKILL])
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
        let signals = LiveProcessGroupSignalRecorder()
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
            readinessProbe: { _ in readRecordedProcessID(at: processMarker) != nil },
            processGroups: liveProcessGroups(recording: signals)
        )

        #expect(await preview.start(siteID: "cooperative", siteRoot: base, port: 4_711).state == .running)
        guard let recordedProcessID = await waitForRecordedProcessID(at: processMarker) else {
            throw QuasarError.processFailed("cooperative preview did not record its process ID")
        }
        processID = recordedProcessID
        #expect(await preview.stop(siteID: "cooperative"))
        #expect(FileManager.default.fileExists(atPath: termMarker.path))
        #expect(await waitForExactProcessExit(recordedProcessID))
        #expect(
            signals.snapshot() == [SIGTERM, SIGINT, SIGKILL],
            "manager must retire the anchored group after the cooperative child handles TERM"
        )
        #expect(await preview.stop(siteID: "cooperative"))
        #expect(await preview.status(siteID: "cooperative").state == .stopped)
        processID = nil
    }

    @Test func ordinaryCommandRetainsValidatedSupervisorThroughGracefulSignals() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let probes = AnchoredSupervisorSignalProbe()
        defer { terminateExactProcessIDs(probes.supervisorProcessIDs) }
        let preview = QuasarPreviewManager(
            readinessAttempts: 100,
            pollInterval: .milliseconds(10),
            command: .init(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: { _ in ["sleep", "30"] }
            ),
            readinessProbe: { _ in
                try? await Task.sleep(for: .milliseconds(50))
                return true
            },
            processGroups: probes.processGroups
        )

        #expect(await preview.start(siteID: "ordinary-anchor", siteRoot: base, port: 4_723).state == .running)
        let supervisorProcessID = try #require(probes.supervisorProcessIDs.first)
        #expect(supervisorProcessID == probes.validatedGroupID)
        #expect(exactProcessExists(supervisorProcessID))
        #expect(processGroupID(of: supervisorProcessID) == supervisorProcessID)

        #expect(await preview.stop(siteID: "ordinary-anchor"))
        let observations = probes.observations
        #expect(observations.map(\.signal) == [SIGTERM, SIGINT])
        #expect(
            observations.allSatisfy {
                $0.supervisorProcessID == supervisorProcessID
                    && $0.supervisorExists
                    && $0.currentGroupID == supervisorProcessID
            },
            "the validated supervisor must remain the same private-group leader after TERM and INT"
        )
        #expect(probes.signals == [SIGTERM, SIGINT, SIGKILL])
        #expect(await waitForExactProcessExit(supervisorProcessID))
        #expect(await preview.status(siteID: "ordinary-anchor").state == .stopped)
    }

    @Test func terminalGroupProofPreventsNumericReuseSignals() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let processMarker = base.appendingPathComponent("process")
        let probes = ProcessGroupProbeRecorder()
        var processID: Int32?
        defer { if let processID { terminateExactProcessIDs([processID]) } }
        let processGroups = QuasarProcessGroupSystem(
            processGroupID: { $0 },
            currentProcessGroupID: { currentProcessGroupID() },
            signalGroup: { _, _ in probes.recordSignal() },
            liveness: { _ in probes.nextLiveness() }
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

        #expect(await preview.start(siteID: "retired-group", siteRoot: base, port: 4_718).state == .running)
        guard let recordedProcessID = await waitForRecordedProcessID(at: processMarker) else {
            throw QuasarError.processFailed("retired-group preview did not record its process ID")
        }
        processID = recordedProcessID
        #expect(await preview.stop(siteID: "retired-group"))
        #expect(probes.snapshot() == .init(liveness: 0, signals: 1))

        #expect(await preview.stop(siteID: "retired-group"))
        #expect(
            probes.snapshot() == .init(liveness: 0, signals: 1),
            "a terminal generation probed or signalled its recycled numeric PGID"
        )

        if let processID {
            terminateExactProcessIDs([processID])
            #expect(await waitForExactProcessExit(processID))
        }
        processID = nil
    }

    @Test func ownershipLostRetirementCannotBecomeSuccessfulThroughReentrantTermination() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let firstMarker = base.appendingPathComponent("first-process")
        let replacementMarker = base.appendingPathComponent("replacement-process")
        let probes = ReentrantTerminationProbe()
        let readiness = FirstPreviewReadinessGate()
        defer {
            terminateExactProcessIDs(
                probes.validatedGroupIDs
                    + [readRecordedProcessID(at: firstMarker), readRecordedProcessID(at: replacementMarker)]
                    .compactMap { $0 }
            )
        }
        let processGroups = QuasarProcessGroupSystem(
            processGroupID: probes.validate,
            currentProcessGroupID: { currentProcessGroupID() },
            signalGroup: probes.signal,
            liveness: probes.liveness
        )
        let preview = QuasarPreviewManager(
            readinessAttempts: 1,
            pollInterval: .milliseconds(1),
            command: .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: { port in
                    let marker = port == 4_719 ? firstMarker : replacementMarker
                    return [
                        "-c",
                        "printf '%s\\n' \"$$\" > \"$1\"; exec sleep 30",
                        "quasar-preview",
                        marker.path,
                    ]
                }
            ),
            readinessProbe: { _ in await readiness.probe() },
            processGroups: processGroups
        )

        let starting = Task {
            await preview.start(siteID: "ownership-lost", siteRoot: base, port: 4_719)
        }
        await readiness.waitUntilFirstProbeStarted()
        let firstProcessID = try #require(await waitForRecordedProcessID(at: firstMarker))
        let stopping = Task { await preview.stop(siteID: "ownership-lost") }
        #expect(await waitForRecordedSignal(probes))
        await readiness.releaseFirstProbe()

        #expect((await starting.value).state == .crashed)
        #expect(
            !(await stopping.value),
            "a reentrant termination upgraded ownership loss into group-exit proof"
        )

        let replacement = await preview.start(siteID: "ownership-lost", siteRoot: base, port: 4_720)
        #expect(replacement.state == .crashed)
        #expect(replacement.logTail == ["Prior preview process did not stop; replacement was not launched."])
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            !FileManager.default.fileExists(atPath: replacementMarker.path),
            "replacement launched after the prior group capability lost ownership without exit proof"
        )
        #expect(probes.validatedGroupIDs.count == 1)

        terminateExactProcessIDs([firstProcessID])
        #expect(await waitForExactProcessExit(firstProcessID))
    }

    @Test func failedStartupKillsDescendantAfterLeaderExits() async throws {
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
                        "(trap '' TERM INT; while :; do printf 'descendant\\n' >> \"$2\"; sleep 0.02; done) & child=$!; printf '%s %s\\n' \"$$\" \"$child\" > \"$1\"; sleep 0.2; exit 0",
                        "quasar-preview",
                        processMarker.path,
                        activity.path,
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
        let activityAtReturn = try Data(contentsOf: activity)
        try await Task.sleep(for: .milliseconds(250))
        let activityAfterObservation = try Data(contentsOf: activity)
        #expect(leaderExited)
        #expect(
            activityAfterObservation == activityAtReturn,
            "descendant activity continued after startup-failure cleanup returned"
        )
        #if os(Linux)
        #expect(descendantExited, "descendant survived startup-failure group cleanup")
        #else
        _ = descendantExited // A Darwin zombie is inert even before its new parent reaps it.
        #endif
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
            #expect(
                !FileManager.default.fileExists(atPath: processMarker.path),
                "invalid ownership validation launched the actual preview command"
            )
            if let processID = await waitForRecordedProcessID(at: processMarker) {
                #expect(await waitForExactProcessExit(processID), "invalid-group leader survived fail-closed cleanup")
                terminateExactProcessIDs([processID])
            }
        }
    }

    @Test func delayedInvalidOwnershipValidationDoesNotLaunchPreviewCommand() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let processMarker = base.appendingPathComponent("processes")
        var recordedProcessIDs: [Int32] = []
        defer {
            terminateExactProcessIDs(recordedProcessIDs + (readRecordedProcessIDs(at: processMarker) ?? []))
        }
        let processGroups = QuasarProcessGroupSystem(
            processGroupID: { _ in
                Thread.sleep(forTimeInterval: 0.1)
                return nil
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
                arguments: { _ in
                    [
                        "-c",
                        "trap '' TERM INT; (trap '' TERM INT; while :; do sleep 0.05; done) & child=$!; printf '%s %s\\n' \"$$\" \"$child\" > \"$1\"; while :; do sleep 0.05; done",
                        "quasar-preview",
                        processMarker.path,
                    ]
                }
            ),
            readinessProbe: { _ in true },
            processGroups: processGroups
        )

        let status = await preview.start(siteID: "early-exit", siteRoot: base, port: 4_717)
        #expect(status.state == .crashed)
        #expect(status.logTail.contains { $0.contains("private owned process group") })
        recordedProcessIDs = readRecordedProcessIDs(at: processMarker) ?? []
        #expect(
            recordedProcessIDs.isEmpty,
            "delayed invalid validation launched the actual preview command or its descendant"
        )
    }

    @Test func linuxKernelProbeTransitionsFailClosed() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let stat = base.appendingPathComponent("123/stat")
        try FileManager.default.createDirectory(at: stat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("123 (worker name) S 1 4242 0 0".utf8).write(to: stat, options: .atomic)

        let presentThenAbsent = KernelGroupProbeSequence([.delivered, .absent])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: base,
                groupProbe: presentThenAbsent.next
            ) == .unverifiable,
            "a group disappearing during procfs enumeration is not a stable snapshot"
        )
        #expect(presentThenAbsent.callCount == 2)

        let absentThenPresent = KernelGroupProbeSequence([.absent, .delivered])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: base,
                groupProbe: absentThenPresent.next
            ) == .unverifiable,
            "a PGID appearing after ESRCH may be a recycled unrelated group"
        )
        #expect(absentThenPresent.callCount == 2)

        let failedThenPresent = KernelGroupProbeSequence([.failed, .delivered])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: base,
                groupProbe: failedThenPresent.next
            ) == .unverifiable
        )
        #expect(failedThenPresent.callCount == 2)

        let presentThenFailed = KernelGroupProbeSequence([.delivered, .failed])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: base,
                groupProbe: presentThenFailed.next
            ) == .unverifiable
        )
        #expect(presentThenFailed.callCount == 2)
    }

    @Test func linuxStableKernelProbesClassifyOnlyCompleteProcfsSnapshots() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stableAbsent = KernelGroupProbeSequence([.absent, .absent])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: missing,
                groupProbe: stableAbsent.next
            ) == .absent,
            "stable kernel ESRCH is authoritative even when procfs is unavailable"
        )
        #expect(stableAbsent.callCount == 2)

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let stablePresentEmpty = KernelGroupProbeSequence([.delivered, .delivered])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: empty,
                groupProbe: stablePresentEmpty.next
            ) == .unverifiable,
            "a kernel-visible group with no visible procfs member is incomplete"
        )
        #expect(stablePresentEmpty.callCount == 2)

        let incomplete = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: incomplete.appendingPathComponent("123"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: incomplete) }
        let stablePresentIncomplete = KernelGroupProbeSequence([.delivered, .delivered])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: incomplete,
                groupProbe: stablePresentIncomplete.next
            ) == .unverifiable,
            "a listed PID whose stat disappeared must fail closed"
        )
        #expect(stablePresentIncomplete.callCount == 2)

        let complete = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: complete) }
        let stat = complete.appendingPathComponent("123/stat")
        try FileManager.default.createDirectory(at: stat.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data("malformed".utf8).write(to: stat, options: .atomic)
        let stableAbsentMalformed = KernelGroupProbeSequence([.absent, .absent])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: complete,
                groupProbe: stableAbsentMalformed.next
            ) == .absent,
            "stable kernel ESRCH is authoritative even when procfs is malformed"
        )
        #expect(stableAbsentMalformed.callCount == 2)

        try Data("123 (worker name) Z 1 4242 0 0".utf8).write(to: stat, options: .atomic)
        let stableZombie = KernelGroupProbeSequence([.delivered, .delivered])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: complete,
                groupProbe: stableZombie.next
            ) == .zombieOnly
        )
        #expect(stableZombie.callCount == 2)

        try Data("123 (worker name) S 1 4242 0 0".utf8).write(to: stat, options: .atomic)
        let stableLive = KernelGroupProbeSequence([.delivered, .delivered])
        #expect(
            QuasarProcessGroupSystem.linuxLiveness(
                groupID: 4_242,
                procRoot: complete,
                groupProbe: stableLive.next
            ) == .live
        )
        #expect(stableLive.callCount == 2)
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
}

private final class LiveProcessGroupSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [Int32] = []

    func record(_ signal: Int32) {
        lock.lock(); defer { lock.unlock() }
        signals.append(signal)
    }

    func snapshot() -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        return signals
    }
}

private final class AnchoredSupervisorSignalProbe: @unchecked Sendable {
    struct Observation: Sendable {
        let signal: Int32
        let supervisorProcessID: Int32
        let supervisorExists: Bool
        let currentGroupID: Int32
    }

    private let lock = NSLock()
    private var recordedSupervisorProcessIDs: [Int32] = []
    private var recordedGroupID: Int32?
    private var recordedSignals: [Int32] = []
    private var recordedObservations: [Observation] = []

    var processGroups: QuasarProcessGroupSystem {
        let live = QuasarProcessGroupSystem.live
        return .init(
            processGroupID: { [self] processID in
                let groupID = live.processGroupID(processID)
                lock.lock()
                if !recordedSupervisorProcessIDs.contains(processID) {
                    recordedSupervisorProcessIDs.append(processID)
                }
                if recordedGroupID == nil { recordedGroupID = groupID }
                lock.unlock()
                return groupID
            },
            currentProcessGroupID: live.currentProcessGroupID,
            signalGroup: { [self] groupID, signal in
                lock.lock()
                recordedSignals.append(signal)
                let supervisorProcessID = recordedSupervisorProcessIDs.first
                lock.unlock()
                if let previousSignal = previousSignal(for: signal), let supervisorProcessID {
                    let observation = Observation(
                        signal: previousSignal,
                        supervisorProcessID: supervisorProcessID,
                        supervisorExists: exactProcessExists(supervisorProcessID),
                        currentGroupID: processGroupID(of: supervisorProcessID)
                    )
                    lock.lock()
                    recordedObservations.append(observation)
                    lock.unlock()
                }
                return live.signalGroup(groupID, signal)
            },
            liveness: live.liveness
        )
    }

    var supervisorProcessIDs: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return recordedSupervisorProcessIDs
    }

    var validatedGroupID: Int32? {
        lock.lock(); defer { lock.unlock() }
        return recordedGroupID
    }

    var signals: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return recordedSignals
    }

    var observations: [Observation] {
        lock.lock(); defer { lock.unlock() }
        return recordedObservations
    }

    private func previousSignal(for signal: Int32) -> Int32? {
        switch signal {
        case SIGINT: return SIGTERM
        case SIGKILL: return SIGINT
        default: return nil
        }
    }
}

private func liveProcessGroups(recording recorder: LiveProcessGroupSignalRecorder) -> QuasarProcessGroupSystem {
    let live = QuasarProcessGroupSystem.live
    return .init(
        processGroupID: live.processGroupID,
        currentProcessGroupID: live.currentProcessGroupID,
        signalGroup: { groupID, signal in
            recorder.record(signal)
            return live.signalGroup(groupID, signal)
        },
        liveness: live.liveness
    )
}

private final class KernelGroupProbeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [QuasarGroupSignalResult]
    private var index = 0

    init(_ results: [QuasarGroupSignalResult]) {
        self.results = results
    }

    func next(_ groupID: Int32) -> QuasarGroupSignalResult {
        _ = groupID
        lock.lock(); defer { lock.unlock() }
        guard index < results.count else { return .failed }
        defer { index += 1 }
        return results[index]
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return index
    }
}

private actor FirstPreviewReadinessGate {
    private var callCount = 0
    private var firstProbeStarted = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func probe() async -> Bool {
        callCount += 1
        guard callCount == 1 else { return true }
        firstProbeStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilFirstProbeStarted() async {
        while !firstProbeStarted { await Task.yield() }
    }

    func releaseFirstProbe() {
        continuation?.resume(returning: false)
        continuation = nil
    }
}

private final class ReentrantTerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var groupIDs: [Int32] = []
    private var livenessCalls = 0
    private var signalCalls = 0

    func validate(_ processID: Int32) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if !groupIDs.contains(processID) { groupIDs.append(processID) }
        return processID
    }

    func signal(_ groupID: Int32, _ signal: Int32) -> QuasarGroupSignalResult {
        _ = groupID
        _ = signal
        lock.lock(); defer { lock.unlock() }
        signalCalls += 1
        return .delivered
    }

    func liveness(_ groupID: Int32) -> QuasarProcessGroupLiveness {
        _ = groupID
        let call: Int
        let processToTerminate: Int32?
        lock.lock()
        livenessCalls += 1
        call = livenessCalls
        processToTerminate = call == 3 ? groupIDs.first : nil
        lock.unlock()

        if let processToTerminate {
            terminateExactProcessIDs([processToTerminate])
            for _ in 0..<200 where exactProcessExists(processToTerminate) {
                Thread.sleep(forTimeInterval: 0.005)
            }
            return .unverifiable
        }
        return call < 3 ? .live : .unverifiable
    }

    var hasRecordedSignal: Bool {
        lock.lock(); defer { lock.unlock() }
        return signalCalls > 0
    }

    var validatedGroupIDs: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return groupIDs
    }
}

private func waitForRecordedSignal(_ probes: ReentrantTerminationProbe) async -> Bool {
    for _ in 0..<200 {
        if probes.hasRecordedSignal { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return probes.hasRecordedSignal
}

private final class ProcessGroupProbeRecorder: @unchecked Sendable {
    struct Snapshot: Equatable {
        var liveness: Int
        var signals: Int
    }

    private let lock = NSLock()
    private var livenessCalls = 0
    private var signalCalls = 0

    func nextLiveness() -> QuasarProcessGroupLiveness {
        lock.lock(); defer { lock.unlock() }
        livenessCalls += 1
        return livenessCalls == 1 ? .absent : .live
    }

    func recordSignal() -> QuasarGroupSignalResult {
        lock.lock(); defer { lock.unlock() }
        signalCalls += 1
        return .absent
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(liveness: livenessCalls, signals: signalCalls)
    }
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

private final class SupervisorLossReuseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var validated: [Int32] = []
    private var recordedSignals: [Int32] = []
    private var lostSupervisorID: Int32?

    func validate(_ processID: Int32) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard processID != lostSupervisorID else { return nil }
        if !validated.contains(processID) { validated.append(processID) }
        return processID
    }

    func signal(_ groupID: Int32, _ signal: Int32) -> QuasarGroupSignalResult {
        let shouldDropSupervisor: Bool
        lock.lock()
        recordedSignals.append(signal)
        shouldDropSupervisor = recordedSignals.count == 1
        // Model ownership loss independently of Foundation's asynchronous
        // child reaping. A live numeric PGID must not restore the lost anchor.
        if shouldDropSupervisor { lostSupervisorID = groupID }
        lock.unlock()

        if shouldDropSupervisor {
            terminateExactProcessIDs([groupID])
        }
        return .delivered
    }

    func liveness(_ groupID: Int32) -> QuasarProcessGroupLiveness {
        _ = groupID
        return .live
    }

    var supervisorProcessIDs: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return validated
    }

    var signals: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return recordedSignals
    }
}
