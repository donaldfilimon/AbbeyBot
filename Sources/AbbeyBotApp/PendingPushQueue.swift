import Foundation

/// Durable JSONL outbox for `AbbeyServerClient` POSTs that failed to reach the server
/// (network blip, server down). Mirrors `AbbeyCore.ExperienceJournal`'s append-only-file
/// shape, but is drainable: a successful `drain` rewrites the file to keep only the
/// entries that still failed, instead of growing forever.
///
/// Queue instances targeting the same path share a coordinator. File I/O is serialized,
/// while network sends remain outside the lock; a drain merges records appended during
/// those awaits before it commits its rewrite.
public struct PendingPushQueue: Sendable {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let coordination: Coordination

    public init(url: URL) {
        self.url = url
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        self.coordination = CoordinationRegistry.shared.coordination(for: url)
    }

    public static func defaultURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".abbey", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-pushes.jsonl", isDirectory: false)
    }

    private struct Record: Codable {
        var path: String
        var bodyJSON: Data
        var enqueuedAt: Date
    }

    public enum QueueError: Error, LocalizedError, Sendable {
        case io(String)
        case encode(String)
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .io(let detail): return "Pending push queue I/O: \(detail)"
            case .encode(let detail): return "Pending push queue encode failed: \(detail)"
            case .corrupt(let detail): return "Pending push queue corrupt: \(detail)"
            }
        }
    }

    /// Append one failed push for later retry.
    public func enqueue(path: String, jsonObjectBody: [String: Any]) throws {
        let bodyJSON: Data
        do {
            bodyJSON = try JSONSerialization.data(withJSONObject: jsonObjectBody)
        } catch {
            throw QueueError.encode(error.localizedDescription)
        }
        let record = Record(path: path, bodyJSON: bodyJSON, enqueuedAt: Date())
        try coordination.withLock {
            try appendLine(record)
        }
    }

    /// Attempt to resend every queued entry via `send(path, bodyJSON) -> succeeded`, in
    /// enqueue order. Rewrites the file to keep only entries that still failed. Returns
    /// the number successfully sent.
    @discardableResult
    public func drain(send: (String, Data) async -> Bool) async throws -> Int {
        let records: [Record]? = try coordination.withLock {
            guard !coordination.drainInProgress else { return nil }
            let records = try readAll()
            coordination.drainInProgress = true
            return records
        }
        guard let records else { return 0 }
        guard !records.isEmpty else {
            coordination.withLock { coordination.drainInProgress = false }
            return 0
        }

        defer {
            coordination.withLock { coordination.drainInProgress = false }
        }

        var stillPending: [Record] = []
        var sentCount = 0
        for record in records {
            if await send(record.path, record.bodyJSON) {
                sentCount += 1
            } else {
                stillPending.append(record)
            }
        }

        try coordination.withLock {
            // `enqueue` only appends while this drain is in flight and another drain is
            // excluded, so everything after the snapshot prefix is newly queued work.
            // Preserve it after the snapshot records whose sends failed.
            let current = try readAll()
            guard current.count >= records.count else {
                throw QueueError.io("queue changed unexpectedly while draining")
            }
            let appendedDuringDrain = current.dropFirst(records.count)
            try rewrite(stillPending + appendedDuringDrain)
        }
        return sentCount
    }

    public func pendingCount() throws -> Int {
        try coordination.withLock {
            try readAll().count
        }
    }

    // MARK: - File I/O

    private func appendLine(_ record: Record) throws {
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw QueueError.encode(error.localizedDescription)
        }
        var line = data
        line.append(contentsOf: [0x0A])
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch let error as QueueError {
            throw error
        } catch {
            throw QueueError.io(error.localizedDescription)
        }
    }

    private func readAll() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw QueueError.io(error.localizedDescription)
        }
        guard !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        var out: [Record] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            do {
                out.append(try decoder.decode(Record.self, from: Data(line.utf8)))
            } catch {
                throw QueueError.corrupt(error.localizedDescription)
            }
        }
        return out
    }

    private func rewrite(_ records: [Record]) throws {
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var data = Data()
        for record in records {
            let encoded: Data
            do {
                encoded = try encoder.encode(record)
            } catch {
                throw QueueError.encode(error.localizedDescription)
            }
            data.append(encoded)
            data.append(contentsOf: [0x0A])
        }
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw QueueError.io(error.localizedDescription)
        }
    }
}

private final class Coordination: @unchecked Sendable {
    private let lock = NSLock()
    var drainInProgress = false

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

/// Strongly retains one coordinator per normalized queue path. The number of queue paths
/// is bounded in production (normally one), and sharing also protects independently
/// constructed queue values in tests or future client instances.
private final class CoordinationRegistry: @unchecked Sendable {
    static let shared = CoordinationRegistry()

    private let lock = NSLock()
    private var coordinators: [String: Coordination] = [:]

    func coordination(for url: URL) -> Coordination {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = coordinators[key] {
            return existing
        }
        let created = Coordination()
        coordinators[key] = created
        return created
    }
}
