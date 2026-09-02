import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
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
    private struct Entry {
        var generationID: UUID
        var process: Process
        var pipe: Pipe
        var logs: LogBuffer
        var status: PreviewStatus
    }
    private var entries: [String: Entry] = [:]
    private let readinessAttempts: Int
    private let pollInterval: Duration
    private let command: QuasarPreviewCommand
    private let readinessProbe: @Sendable (URL) async -> Bool

    public init(
        readinessAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(500),
        command: QuasarPreviewCommand = .bunNext,
        readinessProbe: (@Sendable (URL) async -> Bool)? = nil
    ) {
        self.readinessAttempts = min(max(readinessAttempts, 1), 120)
        self.pollInterval = pollInterval
        self.command = command
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
        let generationID = UUID()
        entries[siteID] = Entry(
            generationID: generationID,
            process: process,
            pipe: pipe,
            logs: logs,
            status: .init(state: .starting, port: port)
        )
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        for _ in 0..<readinessAttempts {
            guard entries[siteID]?.generationID == generationID else {
                _ = await terminate(process)
                return .init(state: .stopped, logTail: logs.lines())
            }
            if !process.isRunning { break }
            if await readinessProbe(url) {
                let status = PreviewStatus(state: .running, port: port, url: url.absoluteString, logTail: logs.lines())
                guard entries[siteID]?.generationID == generationID else {
                    _ = await terminate(process)
                    return .init(state: .stopped, logTail: logs.lines())
                }
                entries[siteID]?.status = status
                return status
            }
            try? await Task.sleep(for: pollInterval)
        }
        let stopped = await terminate(process)
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
        let stopped = await terminate(entry.process)
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

    private func terminate(_ process: Process) async -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if await waitForExit(process) { return true }
        process.interrupt()
        return await waitForExit(process)
    }

    private func waitForExit(_ process: Process) async -> Bool {
        for _ in 0..<40 {
            guard !Self.hasExited(process) else { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return Self.hasExited(process)
    }

    private nonisolated static func hasExited(_ process: Process) -> Bool {
        guard process.isRunning else { return true }
        #if os(Linux)
        // swift-corelibs-foundation flips `isRunning` only after its manager
        // thread reaps the child. Under load, a child that has already exited
        // can remain a zombie beyond this manager's bounded grace period. A
        // zombie cannot execute or write into a site, so it satisfies the
        // archive safety contract even while Foundation catches up.
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
