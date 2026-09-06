import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct QuasarPreviewCommand: Sendable {
    public var executableURL: URL
    public var arguments: @Sendable (_ port: Int) -> [String]

    public init(
        executableURL: URL,
        arguments: @escaping @Sendable (_ port: Int) -> [String]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public static let bunNext = Self(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: {
            let configuredBind = ProcessInfo.processInfo.environment["ABBEY_QUASAR_PREVIEW_BIND_HOST"]
            let bind = configuredBind == "0.0.0.0" ? "0.0.0.0" : "127.0.0.1"
            return [
                "bun", QuasarDependencyPreparer.nextEntryPoint, "dev",
                "--hostname", bind, "--port", String($0),
            ]
        }
    )
}

enum QuasarProcessGroupLiveness: Sendable, Equatable {
    case absent
    case zombieOnly
    case live
    case unverifiable

    var satisfiesExitProof: Bool {
        self == .absent
    }
}

enum QuasarGroupSignalResult: Sendable, Equatable {
    case delivered
    case absent
    case failed
}

struct QuasarProcessGroupSystem: Sendable {
    var processGroupID: @Sendable (Int32) -> Int32?
    var currentProcessGroupID: @Sendable () -> Int32?
    var signalGroup: @Sendable (_ groupID: Int32, _ signal: Int32) -> QuasarGroupSignalResult
    var liveness: @Sendable (_ groupID: Int32) -> QuasarProcessGroupLiveness

    private static func signalProcessGroup(
        _ groupID: Int32,
        signal: Int32
    ) -> QuasarGroupSignalResult {
        guard groupID > 1 else { return .failed }
        let result: Int32
        #if canImport(Darwin)
        result = Darwin.kill(-groupID, signal)
        #elseif canImport(Glibc)
        result = Glibc.kill(-groupID, signal)
        #elseif canImport(Musl)
        result = Musl.kill(-groupID, signal)
        #else
        return .failed
        #endif
        if result == 0 { return .delivered }
        return errno == ESRCH ? .absent : .failed
    }

    static let live = Self(
        processGroupID: { processID in
            let groupID: Int32
            #if canImport(Darwin)
            groupID = Darwin.getpgid(processID)
            #elseif canImport(Glibc)
            groupID = Glibc.getpgid(processID)
            #elseif canImport(Musl)
            groupID = Musl.getpgid(processID)
            #else
            return nil
            #endif
            return groupID > 0 ? groupID : nil
        },
        currentProcessGroupID: {
            #if canImport(Darwin)
            return Darwin.getpgrp()
            #elseif canImport(Glibc)
            return Glibc.getpgrp()
            #elseif canImport(Musl)
            return Musl.getpgrp()
            #else
            return nil
            #endif
        },
        signalGroup: { groupID, signal in signalProcessGroup(groupID, signal: signal) },
        liveness: { groupID in
            guard groupID > 1 else { return .unverifiable }
            #if os(Linux)
            return Self.linuxLiveness(
                groupID: groupID,
                procRoot: URL(fileURLWithPath: "/proc"),
                groupProbe: { signalProcessGroup($0, signal: 0) }
            )
            #elseif canImport(Darwin)
            if Darwin.kill(-groupID, 0) == 0 { return .live }
            return errno == ESRCH ? .absent : .unverifiable
            #else
            return .unverifiable
            #endif
        }
    )

    static func linuxLiveness(
        groupID: Int32,
        procRoot: URL,
        groupProbe: @Sendable (Int32) -> QuasarGroupSignalResult = {
            signalProcessGroup($0, signal: 0)
        }
    ) -> QuasarProcessGroupLiveness {
        guard groupID > 1 else { return .unverifiable }
        let before = groupProbe(groupID)
        let snapshot = linuxProcfsSnapshot(groupID: groupID, procRoot: procRoot)
        let after = groupProbe(groupID)
        guard before == after else {
            // The group appeared, disappeared, or became unverifiable while
            // procfs was enumerated. No classification from that interval can
            // safely be attached to the retained numeric PGID.
            return .unverifiable
        }
        switch (before, after) {
        case (.absent, .absent):
            // Two atomic ESRCH results bracketing the snapshot are the stable
            // absence contract. Stale procfs entries cannot weaken that proof.
            return .absent
        case (.delivered, .delivered):
            guard snapshot.complete else { return .unverifiable }
            switch snapshot.liveness {
            case .live, .zombieOnly: return snapshot.liveness
            case .absent:
                // The kernel saw the group on both sides, but procfs exposed
                // no member. Treat incomplete visibility or membership churn
                // as unverifiable rather than inventing a stable live member.
                return .unverifiable
            case .unverifiable:
                return .unverifiable
            }
        case (.failed, .failed):
            return .unverifiable
        default:
            return .unverifiable
        }
    }

    private struct LinuxProcfsSnapshot {
        var liveness: QuasarProcessGroupLiveness
        var complete: Bool
    }

    private static func linuxProcfsSnapshot(
        groupID: Int32,
        procRoot: URL
    ) -> LinuxProcfsSnapshot {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: procRoot.path) else {
            return .init(liveness: .unverifiable, complete: false)
        }
        var foundZombie = false
        var foundLive = false
        var complete = true
        for entry in entries where !entry.isEmpty && entry.allSatisfy(\.isNumber) {
            guard let processID = Int32(entry), processID > 0 else {
                return .init(liveness: .unverifiable, complete: false)
            }
            let statURL = procRoot.appendingPathComponent(entry).appendingPathComponent("stat")
            guard let stat = try? String(contentsOf: statURL, encoding: .utf8) else {
                if !fileManager.fileExists(atPath: statURL.path) {
                    complete = false
                    continue
                }
                return .init(liveness: .unverifiable, complete: false)
            }
            guard let commandEnd = stat.lastIndex(of: ")") else {
                return .init(liveness: .unverifiable, complete: false)
            }
            let fields = stat[stat.index(after: commandEnd)...].split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, fields[0].count == 1, let memberGroupID = Int32(fields[2]) else {
                return .init(liveness: .unverifiable, complete: false)
            }
            guard memberGroupID == groupID else { continue }
            if fields[0] == "Z" || fields[0] == "X" {
                foundZombie = true
            } else {
                foundLive = true
            }
        }
        let liveness: QuasarProcessGroupLiveness = foundLive ? .live : (foundZombie ? .zombieOnly : .absent)
        return .init(liveness: liveness, complete: complete)
    }
}

public actor QuasarPreviewManager {
    private final class LogBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffered = ""
        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            buffered += String(decoding: data, as: UTF8.self)
            if buffered.utf8.count > 16_384 { buffered = String(buffered.suffix(16_384)) }
        }
        func lines() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return QuasarPreviewManager.lines(buffered)
        }
    }
    private final class OwnedProcessGroup: @unchecked Sendable {
        private enum State: Sendable {
            case active
            case exitProven
            case ownershipLost
        }

        let leaderPID: Int32
        let groupID: Int32
        private let lock = NSLock()
        private var state = State.active

        init(leaderPID: Int32, groupID: Int32) {
            self.leaderPID = leaderPID
            self.groupID = groupID
        }

        var isActive: Bool {
            lock.lock(); defer { lock.unlock() }
            return state == .active
        }

        var terminalResult: Bool? {
            lock.lock(); defer { lock.unlock() }
            switch state {
            case .active: return nil
            case .exitProven: return true
            case .ownershipLost: return false
            }
        }

        @discardableResult
        func markExitProven() -> Bool {
            lock.lock(); defer { lock.unlock() }
            switch state {
            case .active:
                state = .exitProven
                return true
            case .exitProven:
                return true
            case .ownershipLost:
                return false
            }
        }

        @discardableResult
        func markOwnershipLost() -> Bool {
            lock.lock(); defer { lock.unlock() }
            switch state {
            case .active:
                state = .ownershipLost
                return false
            case .exitProven:
                return true
            case .ownershipLost:
                return false
            }
        }
    }

    private final class LaunchGate: @unchecked Sendable {
        let pipe = Pipe()
        private let lock = NSLock()
        private var closed = false
        private var released = false

        func release() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !closed, !released else { return false }
            do {
                try pipe.fileHandleForWriting.write(contentsOf: Data("launch\n".utf8))
                released = true
                return true
            } catch {
                closed = true
                pipe.fileHandleForWriting.closeFile()
                return false
            }
        }

        func close() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            pipe.fileHandleForWriting.closeFile()
        }
    }

    private struct ChildLifecycle {
        let marker: String
        private(set) var childExited = false
        private var buffered = ""

        mutating func refresh(from handle: FileHandle) {
            guard !childExited else { return }
            while true {
                let data: Data
                do {
                    guard let next = try handle.read(upToCount: 4_096), !next.isEmpty else { break }
                    data = next
                } catch {
                    break
                }
                buffered += String(decoding: data, as: UTF8.self)
                if buffered.contains(marker) {
                    childExited = true
                    buffered.removeAll(keepingCapacity: false)
                    return
                }
                if buffered.utf8.count > 1_024 {
                    buffered = String(buffered.suffix(1_024))
                }
            }
        }
    }

    private struct Entry {
        var generationID: UUID
        var contentGeneration: String
        var process: Process
        var processGroup: OwnedProcessGroup?
        var groupExitProven: Bool
        var terminationInProgress: Bool
        var launchGate: LaunchGate
        var pipe: Pipe
        var lifecyclePipe: Pipe
        var childLifecycle: ChildLifecycle
        var logs: LogBuffer
        var status: PreviewStatus
    }

    private nonisolated static let supervisorScript = """
        abbey_quasar_signal_interrupted=0
        abbey_quasar_child_status=0
        abbey_quasar_handle_signal() {
          abbey_quasar_signal_interrupted=1
        }
        trap 'abbey_quasar_handle_signal' TERM
        trap 'abbey_quasar_handle_signal' INT
        if ! IFS= read -r abbey_quasar_gate; then
          exit 0
        fi
        if [ "$abbey_quasar_gate" != "launch" ]; then
          exit 0
        fi
        "$@" </dev/null 2>&1
        abbey_quasar_child_status=$?
        printf '%s\\n' "$ABBEY_QUASAR_CHILD_EXIT_MARKER" >&2
        while :; do
          abbey_quasar_signal_interrupted=0
          if IFS= read -r abbey_quasar_hold; then
            continue
          fi
          if [ "$abbey_quasar_signal_interrupted" -eq 1 ]; then
            continue
          fi
          exit "$abbey_quasar_child_status"
        done
        """
    private var entries: [String: Entry] = [:]
    private var isShuttingDown = false
    private var startInProgress = false
    private let readinessAttempts: Int
    private let pollInterval: Duration
    private let command: QuasarPreviewCommand
    private let readinessProbe: @Sendable (URL) async -> Bool
    private let processGroups: QuasarProcessGroupSystem
    public nonisolated let access: QuasarPreviewAccessController

    public init(
        readinessAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(500),
        command: QuasarPreviewCommand = .bunNext,
        readinessProbe: (@Sendable (URL) async -> Bool)? = nil,
        access: QuasarPreviewAccessController = QuasarPreviewAccessController()
    ) {
        self.readinessAttempts = min(max(readinessAttempts, 1), 120)
        self.pollInterval = pollInterval
        self.command = command
        self.processGroups = .live
        self.access = access
        self.readinessProbe = readinessProbe ?? { url in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 2
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
    }

    init(
        readinessAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(500),
        command: QuasarPreviewCommand = .bunNext,
        readinessProbe: (@Sendable (URL) async -> Bool)? = nil,
        processGroups: QuasarProcessGroupSystem,
        access: QuasarPreviewAccessController = QuasarPreviewAccessController()
    ) {
        self.readinessAttempts = min(max(readinessAttempts, 1), 120)
        self.pollInterval = pollInterval
        self.command = command
        self.processGroups = processGroups
        self.access = access
        self.readinessProbe = readinessProbe ?? { url in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 2
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
    }

    public func status(siteID: String) async -> PreviewStatus {
        guard var entry = entries[siteID] else { return PreviewStatus() }
        if entry.processGroup != nil {
            entry.childLifecycle.refresh(from: entry.lifecyclePipe.fileHandleForReading)
        }
        let supervisorExited = !entry.process.isRunning
        if supervisorExited, !entry.terminationInProgress, let group = entry.processGroup {
            let exitProven = processGroups.liveness(group.groupID).satisfiesExitProof
            // Once the supervisor anchor is gone, a later numeric PGID match
            // cannot be proven to be ours. Preserve whether the terminal state
            // came from atomic absence proof or from ownership loss.
            entry.groupExitProven = exitProven
                ? group.markExitProven()
                : group.markOwnershipLost()
            entry.processGroup = nil
            Self.closeTerminalResources(&entry)
        }
        if
            (entry.childLifecycle.childExited || supervisorExited),
            entry.status.state == .running || entry.status.state == .starting
        {
            entry.status = .init(state: .crashed, port: entry.status.port, logTail: entry.logs.lines())
            await access.retire(siteID: siteID)
        } else {
            entry.status.logTail = entry.logs.lines()
        }
        entries[siteID] = entry
        return entry.status
    }

    public func start(siteID: String, siteRoot: URL, port: Int) async -> PreviewStatus {
        await start(
            siteID: siteID,
            generation: UUID().uuidString,
            siteRoot: siteRoot,
            port: port
        )
    }

    public func start(
        siteID: String,
        generation: String,
        siteRoot: URL,
        port: Int
    ) async -> PreviewStatus {
        guard !isShuttingDown else { return .init(state: .stopped) }
        guard !startInProgress else {
            return .init(state: .crashed, port: port, logTail: ["Another preview start is in progress."])
        }
        startInProgress = true
        defer { startInProgress = false }
        await access.retireAll()
        for otherSiteID in Array(entries.keys) where otherSiteID != siteID {
            guard await stop(siteID: otherSiteID) else {
                return .init(
                    state: .crashed,
                    port: port,
                    logTail: ["Another preview process did not stop; replacement was not launched."]
                )
            }
        }
        guard !isShuttingDown else { return .init(state: .stopped) }
        guard await stop(siteID: siteID) else {
            return .init(
                state: .crashed,
                port: port,
                logTail: ["Prior preview process did not stop; replacement was not launched."]
            )
        }
        // stop() can suspend while retiring an earlier process. Shutdown may
        // close admission during that suspension, including for a new site.
        guard !isShuttingDown else { return .init(state: .stopped) }
        let commandArguments = command.arguments(port)
        let launchGate = LaunchGate()
        let lifecyclePipe = Pipe()
        let lifecycleMarker = "ABBEY_QUASAR_CHILD_EXIT_\(UUID().uuidString)"
        let childLifecycle = ChildLifecycle(marker: lifecycleMarker)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            Self.supervisorScript,
            "abbey-quasar-supervisor",
            command.executableURL.path,
        ] + commandArguments
        process.currentDirectoryURL = siteRoot
        process.standardInput = launchGate.pipe
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = lifecyclePipe
        do {
            process.environment = try Self.previewEnvironment(
                siteRoot: siteRoot,
                lifecycleMarker: lifecycleMarker
            )
        } catch {
            launchGate.close()
            return .init(state: .crashed, port: port, logTail: ["Preview runtime directories could not be prepared."])
        }
        let logs = LogBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in logs.append(handle.availableData) }
        guard Self.makeNonBlocking(lifecyclePipe.fileHandleForReading) else {
            launchGate.close()
            pipe.fileHandleForReading.readabilityHandler = nil
            return .init(
                state: .crashed,
                port: port,
                logTail: ["Preview lifecycle channel could not be configured."]
            )
        }
        do { try process.run() }
        catch {
            launchGate.close()
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = PreviewStatus(state: .crashed, port: port, logTail: [Self.redact(error.localizedDescription)])
            return status
        }
        guard let processGroup = validatedProcessGroup(for: process) else {
            // EOF releases only the supervisor. The actual preview argv has
            // not been invoked, so exact-leader cleanup cannot lose a child.
            launchGate.close()
            pipe.fileHandleForReading.readabilityHandler = nil
            let stopped = await terminateUnvalidatedProcess(process)
            var tail = logs.lines()
            tail.append("Preview process did not start in a private owned process group.")
            if !stopped { tail.append("Preview process did not stop after failed group validation.") }
            return .init(state: .crashed, port: port, logTail: tail)
        }
        let generationID = UUID()
        entries[siteID] = Entry(
            generationID: generationID,
            contentGeneration: generation,
            process: process,
            processGroup: processGroup,
            groupExitProven: false,
            terminationInProgress: false,
            launchGate: launchGate,
            pipe: pipe,
            lifecyclePipe: lifecyclePipe,
            childLifecycle: childLifecycle,
            logs: logs,
            status: .init(state: .starting, port: port)
        )
        guard launchGate.release() else {
            entries[siteID]?.terminationInProgress = true
            let stopped = await terminate(processGroup, process: process, launchGate: launchGate)
            var tail = logs.lines()
            tail.append("Preview command was not released after process-group validation.")
            if !stopped { tail.append("Preview process did not stop after termination requests.") }
            let status = PreviewStatus(state: .crashed, port: port, logTail: tail)
            if var entry = entries[siteID], entry.generationID == generationID {
                entry.terminationInProgress = false
                if stopped {
                    entry.processGroup = nil
                    entry.groupExitProven = true
                    Self.closeTerminalResources(&entry)
                }
                entry.status = status
                entries[siteID] = entry
            }
            return status
        }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        for _ in 0..<readinessAttempts {
            guard !isShuttingDown, entries[siteID]?.generationID == generationID else {
                _ = await terminate(processGroup, process: process, launchGate: launchGate)
                return .init(state: .stopped, logTail: logs.lines())
            }
            if refreshChildLifecycle(siteID: siteID, generationID: generationID) || !process.isRunning { break }
            let ready = await readinessProbe(url)
            guard !isShuttingDown, entries[siteID]?.generationID == generationID else {
                _ = await terminate(processGroup, process: process, launchGate: launchGate)
                return .init(state: .stopped, logTail: logs.lines())
            }
            if ready {
                guard
                    !refreshChildLifecycle(siteID: siteID, generationID: generationID),
                    process.isRunning
                else { break }
                let status = PreviewStatus(state: .running, port: port, url: url.absoluteString, logTail: logs.lines())
                entries[siteID]?.status = status
                await access.activate(.init(siteID: siteID, generation: generation, port: port))
                return status
            }
            try? await Task.sleep(for: pollInterval)
        }
        guard !isShuttingDown, entries[siteID]?.generationID == generationID else {
            _ = await terminate(processGroup, process: process, launchGate: launchGate)
            return .init(state: .stopped, logTail: logs.lines())
        }
        if entries[siteID]?.generationID == generationID {
            entries[siteID]?.terminationInProgress = true
        }
        let stopped = await terminate(processGroup, process: process, launchGate: launchGate)
        var tail = logs.lines()
        if !stopped { tail.append("Preview process did not stop after termination requests.") }
        let status = PreviewStatus(state: .crashed, port: port, logTail: tail)
        if var entry = entries[siteID], entry.generationID == generationID {
            entry.terminationInProgress = false
            if stopped {
                entry.processGroup = nil
                entry.groupExitProven = true
                Self.closeTerminalResources(&entry)
            } else if !process.isRunning {
                entry.groupExitProven = processGroup.markOwnershipLost()
                entry.processGroup = nil
                Self.closeTerminalResources(&entry)
            }
            entry.status = status
            entries[siteID] = entry
        }
        return status
    }

    /// Returns only after the owned preview process has actually exited. A
    /// false result keeps archive/move callers from racing a live writer.
    @discardableResult
    public func stop(siteID: String) async -> Bool {
        await access.retire(siteID: siteID)
        guard var entry = entries[siteID] else { return true }
        guard let processGroup = entry.processGroup else {
            if entry.groupExitProven, entry.status.state != .stopped {
                entry.status = .init(state: .stopped, logTail: entry.logs.lines())
                entries[siteID] = entry
            }
            return entry.groupExitProven
        }
        guard !entry.terminationInProgress else { return false }
        entry.terminationInProgress = true
        entries[siteID] = entry
        let stopped = await terminate(processGroup, process: entry.process, launchGate: entry.launchGate)
        guard var current = entries[siteID], current.generationID == entry.generationID else { return stopped }
        current.terminationInProgress = false
        var tail = entry.logs.lines()
        if stopped {
            current.processGroup = nil
            current.groupExitProven = true
            Self.closeTerminalResources(&current)
            current.status = .init(state: .stopped, logTail: tail)
        } else {
            if !entry.process.isRunning {
                current.groupExitProven = processGroup.markOwnershipLost()
                current.processGroup = nil
                Self.closeTerminalResources(&current)
            }
            tail.append("Preview process did not stop after termination requests.")
            current.status = .init(
                state: .crashed,
                port: entry.status.port,
                logTail: tail
            )
        }
        entries[siteID] = current
        return stopped
    }

    public func stopAll() async {
        await access.retireAll()
        for id in entries.keys { _ = await stop(siteID: id) }
    }

    /// Permanently closes preview admission before terminating owned process
    /// groups. `stopAll()` remains reusable for ordinary operator actions.
    public func shutdown() async {
        isShuttingDown = true
        await stopAll()
    }

    public func activePreview(siteID: String) async -> QuasarActivePreview? {
        guard let current = await access.current(), current.siteID == siteID else { return nil }
        guard let entry = entries[siteID], entry.status.state == .running,
              entry.contentGeneration == current.generation
        else {
            await access.retire(siteID: siteID)
            return nil
        }
        return current
    }

    private func validatedProcessGroup(for process: Process) -> OwnedProcessGroup? {
        let leaderPID = process.processIdentifier
        guard leaderPID > 1, process.isRunning else { return nil }
        guard
            let groupID = processGroups.processGroupID(leaderPID),
            let currentGroupID = processGroups.currentProcessGroupID(),
            // The launched leader may exit while the platform identity probes
            // run. Never retain a group identity after that validation race.
            process.isRunning,
            groupID > 1,
            groupID == leaderPID,
            groupID != currentGroupID
        else { return nil }
        return OwnedProcessGroup(leaderPID: leaderPID, groupID: groupID)
    }

    private func refreshChildLifecycle(siteID: String, generationID: UUID) -> Bool {
        guard var entry = entries[siteID], entry.generationID == generationID else { return true }
        entry.childLifecycle.refresh(from: entry.lifecyclePipe.fileHandleForReading)
        let childExited = entry.childLifecycle.childExited
        entries[siteID] = entry
        return childExited
    }

    private func terminate(
        _ group: OwnedProcessGroup,
        process: Process,
        launchGate: LaunchGate
    ) async -> Bool {
        // TERM and INT may stop the direct command, but the supervisor remains
        // the private PGID anchor until an anchored KILL atomically targets the
        // whole group. No later signal is authorized from numeric liveness.
        for signal in [SIGTERM, SIGINT, SIGKILL] {
            if let terminalResult = group.terminalResult {
                if terminalResult { launchGate.close() }
                return terminalResult
            }
            guard isStillSafeToSignal(group, process: process) else {
                let terminalResult = group.terminalResult ?? false
                if terminalResult { launchGate.close() }
                return terminalResult
            }
            switch processGroups.signalGroup(group.groupID, signal) {
            case .absent:
                // ESRCH from a negative-PGID signal is an atomic kernel proof
                // that the group has no remaining member on Darwin or Linux.
                let terminalResult = group.markExitProven()
                if terminalResult { launchGate.close() }
                return terminalResult
            case .delivered:
                let terminalResult: Bool?
                if signal == SIGKILL {
                    terminalResult = await waitForPostKillAbsence(group)
                } else {
                    terminalResult = await waitForAnchoredSignalStage(group, process: process)
                }
                if let terminalResult {
                    if terminalResult { launchGate.close() }
                    return terminalResult
                }
            case .failed:
                return group.terminalResult ?? false
            }
        }
        return group.terminalResult ?? false
    }

    private func isStillSafeToSignal(_ group: OwnedProcessGroup, process: Process) -> Bool {
        guard
            group.isActive,
            group.leaderPID > 1,
            group.groupID > 1,
            group.groupID == group.leaderPID,
            let currentGroupID = processGroups.currentProcessGroupID(),
            group.groupID != currentGroupID
        else {
            _ = group.markOwnershipLost()
            return false
        }
        guard process.isRunning else {
            _ = retireAfterAnchorLoss(group)
            return false
        }
        guard processGroups.processGroupID(group.leaderPID) == group.groupID else {
            _ = group.markOwnershipLost()
            return false
        }
        return true
    }

    private func waitForAnchoredSignalStage(
        _ group: OwnedProcessGroup,
        process: Process
    ) async -> Bool? {
        for _ in 0..<40 {
            if let terminalResult = group.terminalResult { return terminalResult }
            guard process.isRunning else { return retireAfterAnchorLoss(group) }
            guard processGroups.processGroupID(group.leaderPID) == group.groupID else {
                return group.markOwnershipLost()
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return group.terminalResult
    }

    private func waitForPostKillAbsence(_ group: OwnedProcessGroup) async -> Bool {
        for _ in 0..<40 {
            if let terminalResult = group.terminalResult { return terminalResult }
            if processGroups.liveness(group.groupID).satisfiesExitProof {
                return group.markExitProven()
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if processGroups.liveness(group.groupID).satisfiesExitProof {
            return group.markExitProven()
        }
        return group.markOwnershipLost()
    }

    private func retireAfterAnchorLoss(_ group: OwnedProcessGroup) -> Bool {
        if let terminalResult = group.terminalResult { return terminalResult }
        if processGroups.liveness(group.groupID).satisfiesExitProof {
            return group.markExitProven()
        }
        return group.markOwnershipLost()
    }

    private func terminateUnvalidatedProcess(_ process: Process) async -> Bool {
        guard !Self.hasExited(process) else { return true }
        process.terminate()
        if await waitForExactExit(process) { return true }
        process.interrupt()
        if await waitForExactExit(process) { return true }
        Self.killExactProcess(process.processIdentifier)
        return await waitForExactExit(process)
    }

    private func waitForExactExit(_ process: Process) async -> Bool {
        for _ in 0..<40 {
            guard !Self.hasExited(process) else { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return Self.hasExited(process)
    }

    private nonisolated static func killExactProcess(_ processID: Int32) {
        guard processID > 1 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(processID, SIGKILL)
        #elseif canImport(Glibc)
        _ = Glibc.kill(processID, SIGKILL)
        #elseif canImport(Musl)
        _ = Musl.kill(processID, SIGKILL)
        #endif
    }

    private nonisolated static func makeNonBlocking(_ handle: FileHandle) -> Bool {
        let descriptor = handle.fileDescriptor
        let existingFlags: Int32
        #if canImport(Darwin)
        existingFlags = Darwin.fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0 else { return false }
        return Darwin.fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0
        #elseif canImport(Glibc)
        existingFlags = Glibc.fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0 else { return false }
        return Glibc.fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0
        #elseif canImport(Musl)
        existingFlags = Musl.fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0 else { return false }
        return Musl.fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0
        #else
        return false
        #endif
    }

    private nonisolated static func closeTerminalResources(_ entry: inout Entry) {
        entry.launchGate.close()
        entry.pipe.fileHandleForReading.readabilityHandler = nil
        entry.lifecyclePipe.fileHandleForReading.readabilityHandler = nil
    }

    private nonisolated static func previewEnvironment(
        siteRoot: URL,
        lifecycleMarker: String,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: String] {
        let runtime = try QuasarPreviewRuntime.prepare(siteRoot: siteRoot)
        var environment: [String: String] = [
            "ABBEY_QUASAR_CHILD_EXIT_MARKER": lifecycleMarker,
            "HOME": runtime.home.path,
            "TMPDIR": runtime.temporary.path,
            "XDG_CACHE_HOME": runtime.cache.path,
            "BUN_INSTALL_CACHE_DIR": runtime.cache.path,
            "NO_COLOR": "1",
        ]
        for key in ["PATH", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            if let value = inherited[key], !value.isEmpty { environment[key] = value }
        }
        return environment
    }

    private nonisolated static func hasExited(_ process: Process) -> Bool {
        guard process.isRunning else { return true }
        #if os(Linux)
        // swift-corelibs-foundation flips `isRunning` only after its manager
        // thread reaps the child. Under load, a child that has already exited
        // can remain a zombie beyond this manager's bounded grace period. A
        // zombie cannot execute or write into a site, so it satisfies the
        // archive safety contract even while Foundation catches up.
        guard FileManager.default.fileExists(atPath: "/proc/self/stat") else {
            return false
        }
        let statPath = "/proc/\(process.processIdentifier)/stat"
        guard let stat = try? String(contentsOfFile: statPath, encoding: .utf8) else {
            return !FileManager.default.fileExists(atPath: statPath)
        }
        guard let commandEnd = stat.lastIndex(of: ")") else { return false }
        let remainder = stat[stat.index(after: commandEnd)...]
        guard let state = remainder.first(where: { !$0.isWhitespace }) else { return false }
        return state == "Z" || state == "X"
        #else
        return false
        #endif
    }

    nonisolated static func lines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).suffix(50).map { redact(String($0)) }
    }
    nonisolated static func redact(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"(?im)\bauthorization\s*[:=]\s*[^\r\n]+"#,
                with: "Authorization=<redacted>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\b(token|api[-_]?key|secret)\s*[:= ]+\s*\S+"#,
                with: "$1=<redacted>",
                options: .regularExpression
            )
    }
}
