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
        arguments: { ["bun", "x", "next", "dev", "--port", String($0)] }
    )
}

enum QuasarProcessGroupLiveness: Sendable, Equatable {
    case absent
    case zombieOnly
    case live
    case unverifiable

    var satisfiesExitProof: Bool {
        #if os(Linux)
        self == .absent || self == .zombieOnly
        #else
        self == .absent
        #endif
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
        signalGroup: { groupID, signal in
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
        },
        liveness: { groupID in
            guard groupID > 1 else { return .unverifiable }
            #if os(Linux)
            return Self.linuxLiveness(groupID: groupID, procRoot: URL(fileURLWithPath: "/proc"))
            #elseif canImport(Darwin)
            if Darwin.kill(-groupID, 0) == 0 { return .live }
            return errno == ESRCH ? .absent : .unverifiable
            #else
            return .unverifiable
            #endif
        }
    )

    static func linuxLiveness(groupID: Int32, procRoot: URL) -> QuasarProcessGroupLiveness {
        guard groupID > 1 else { return .unverifiable }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: procRoot.path) else {
            return .unverifiable
        }
        var foundZombie = false
        for entry in entries where !entry.isEmpty && entry.allSatisfy(\.isNumber) {
            guard let processID = Int32(entry), processID > 0 else { return .unverifiable }
            let statURL = procRoot.appendingPathComponent(entry).appendingPathComponent("stat")
            guard let stat = try? String(contentsOf: statURL, encoding: .utf8) else {
                if !fileManager.fileExists(atPath: statURL.path) { continue }
                return .unverifiable
            }
            guard let commandEnd = stat.lastIndex(of: ")") else { return .unverifiable }
            let fields = stat[stat.index(after: commandEnd)...].split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, fields[0].count == 1, let memberGroupID = Int32(fields[2]) else {
                return .unverifiable
            }
            guard memberGroupID == groupID else { continue }
            if fields[0] == "Z" || fields[0] == "X" {
                foundZombie = true
            } else {
                return .live
            }
        }
        return foundZombie ? .zombieOnly : .absent
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
    private struct OwnedProcessGroup: Sendable {
        let leaderPID: Int32
        let groupID: Int32
    }
    private struct Entry {
        var generationID: UUID
        var process: Process
        var processGroup: OwnedProcessGroup
        var pipe: Pipe
        var logs: LogBuffer
        var status: PreviewStatus
    }
    private var entries: [String: Entry] = [:]
    private let readinessAttempts: Int
    private let pollInterval: Duration
    private let command: QuasarPreviewCommand
    private let readinessProbe: @Sendable (URL) async -> Bool
    private let processGroups: QuasarProcessGroupSystem

    public init(
        readinessAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(500),
        command: QuasarPreviewCommand = .bunNext,
        readinessProbe: (@Sendable (URL) async -> Bool)? = nil
    ) {
        self.readinessAttempts = min(max(readinessAttempts, 1), 120)
        self.pollInterval = pollInterval
        self.command = command
        self.processGroups = .live
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
        processGroups: QuasarProcessGroupSystem
    ) {
        self.readinessAttempts = min(max(readinessAttempts, 1), 120)
        self.pollInterval = pollInterval
        self.command = command
        self.processGroups = processGroups
        self.readinessProbe = readinessProbe ?? { url in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 2
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
    }

    public func status(siteID: String) -> PreviewStatus {
        guard var entry = entries[siteID] else { return PreviewStatus() }
        if !entry.process.isRunning && (entry.status.state == .running || entry.status.state == .starting) {
            entry.status = .init(state: .crashed, port: entry.status.port, logTail: entry.logs.lines())
            entry.pipe.fileHandleForReading.readabilityHandler = nil
            entries[siteID] = entry
        } else {
            entry.status.logTail = entry.logs.lines()
            entries[siteID] = entry
        }
        return entry.status
    }

    public func start(siteID: String, siteRoot: URL, port: Int) async -> PreviewStatus {
        guard await stop(siteID: siteID) else {
            return .init(
                state: .crashed,
                port: port,
                logTail: ["Prior preview process did not stop; replacement was not launched."]
            )
        }
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments(port)
        process.currentDirectoryURL = siteRoot
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        let logs = LogBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in logs.append(handle.availableData) }
        do { try process.run() }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = PreviewStatus(state: .crashed, port: port, logTail: [Self.redact(error.localizedDescription)])
            return status
        }
        guard let processGroup = validatedProcessGroup(for: process) else {
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
            process: process,
            processGroup: processGroup,
            pipe: pipe,
            logs: logs,
            status: .init(state: .starting, port: port)
        )
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        for _ in 0..<readinessAttempts {
            guard entries[siteID]?.generationID == generationID else {
                _ = await terminate(processGroup, process: process)
                return .init(state: .stopped, logTail: logs.lines())
            }
            if !process.isRunning { break }
            if await readinessProbe(url) {
                let status = PreviewStatus(state: .running, port: port, url: url.absoluteString, logTail: logs.lines())
                guard entries[siteID]?.generationID == generationID else {
                    _ = await terminate(processGroup, process: process)
                    return .init(state: .stopped, logTail: logs.lines())
                }
                entries[siteID]?.status = status
                return status
            }
            try? await Task.sleep(for: pollInterval)
        }
        let stopped = await terminate(processGroup, process: process)
        pipe.fileHandleForReading.readabilityHandler = nil
        var tail = logs.lines()
        if !stopped { tail.append("Preview process did not stop after termination requests.") }
        let status = PreviewStatus(state: .crashed, port: port, logTail: tail)
        if entries[siteID]?.generationID == generationID { entries[siteID]?.status = status }
        return status
    }

    /// Returns only after the owned preview process has actually exited. A
    /// false result keeps archive/move callers from racing a live writer.
    @discardableResult
    public func stop(siteID: String) async -> Bool {
        guard let entry = entries[siteID] else { return true }
        let stopped = await terminate(entry.processGroup, process: entry.process)
        entry.pipe.fileHandleForReading.readabilityHandler = nil
        guard entries[siteID]?.generationID == entry.generationID else { return stopped }
        var tail = entry.logs.lines()
        if stopped {
            entries[siteID]?.status = .init(state: .stopped, logTail: tail)
        } else {
            tail.append("Preview process did not stop after termination requests.")
            entries[siteID]?.status = .init(
                state: .crashed,
                port: entry.status.port,
                logTail: tail
            )
        }
        return stopped
    }

    public func stopAll() async { for id in entries.keys { _ = await stop(siteID: id) } }

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

    private func terminate(_ group: OwnedProcessGroup, process: Process) async -> Bool {
        if processGroups.liveness(group.groupID).satisfiesExitProof { return true }
        for signal in [SIGTERM, SIGINT, SIGKILL] {
            guard isStillSafeToSignal(group) else { return false }
            switch processGroups.signalGroup(group.groupID, signal) {
            case .absent:
                #if os(Linux)
                // Linux group-signalling ESRCH does not replace the required
                // procfs proof. If procfs is unavailable or malformed, stop,
                // replacement, and archive remain fail-closed.
                return processGroups.liveness(group.groupID).satisfiesExitProof
                #else
                // On Darwin ESRCH from the negative-PGID probe is the required
                // group-level absence proof.
                return true
                #endif
            case .delivered:
                if await waitForGroupExit(group) { return true }
            case .failed:
                return false
            }
        }
        return processGroups.liveness(group.groupID).satisfiesExitProof
    }

    private func isStillSafeToSignal(_ group: OwnedProcessGroup) -> Bool {
        guard
            group.leaderPID > 1,
            group.groupID > 1,
            group.groupID == group.leaderPID,
            let currentGroupID = processGroups.currentProcessGroupID(),
            group.groupID != currentGroupID
        else { return false }
        return true
    }

    private func waitForGroupExit(_ group: OwnedProcessGroup) async -> Bool {
        for _ in 0..<40 {
            if processGroups.liveness(group.groupID).satisfiesExitProof { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return processGroups.liveness(group.groupID).satisfiesExitProof
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
