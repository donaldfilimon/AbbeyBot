import Foundation

/// File-backed unix-epoch cursor for CLI pullers/pushers without UserDefaults. One line,
/// seconds since 1970. Missing or unparseable content degrades to nil — a full sync —
/// mirroring the desktop's `SyncCursorStore` semantics (stamp at *start*, persist only after
/// the operation succeeds). Pull and push use separate default files so one cannot advance
/// the other.
public struct SyncCursorFileStore: Sendable {
    public enum Stream: String, Sendable {
        case messages
        case memories
    }

    public let fileURL: URL

    /// Default pull cursor: `~/.abbey/cli-sync-cursor`.
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".abbey", isDirectory: true)
            .appendingPathComponent("cli-sync-cursor", isDirectory: false)
    }

    /// Default push cursor: `~/.abbey/cli-sync-push-cursor` (independent of the pull cursor).
    public static func defaultPushURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".abbey", isDirectory: true)
            .appendingPathComponent("cli-sync-push-cursor", isDirectory: false)
    }

    public init(fileURL: URL = SyncCursorFileStore.defaultURL()) {
        self.fileURL = fileURL
    }

    public func loadLastSuccess() -> Date? {
        loadCursor(at: fileURL)
    }

    /// Loads a stream-specific cursor. Existing installations begin from the legacy
    /// shared push cursor until that stream successfully writes its own sidecar.
    public func loadLastSuccess(for stream: Stream) -> Date? {
        let scopedURL = url(for: stream)
        if FileManager.default.fileExists(atPath: scopedURL.path) {
            return loadCursor(at: scopedURL)
        }
        return loadLastSuccess()
    }

    private func loadCursor(at url: URL) -> Date? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let epoch = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), epoch > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Alias kept for call sites that named the pull-side API explicitly.
    public func loadLastPullSuccess() -> Date? { loadLastSuccess() }

    public func saveLastSuccess(_ date: Date) throws {
        try save(date, at: fileURL)
    }

    /// Saves independent progress for one push stream without advancing any other stream.
    public func saveLastSuccess(_ date: Date, for stream: Stream) throws {
        try save(date, at: url(for: stream))
    }

    private func save(_ date: Date, at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try String(date.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
    }

    private func url(for stream: Stream) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).\(stream.rawValue)",
            isDirectory: false
        )
    }

    /// Alias kept for call sites that named the pull-side API explicitly.
    public func saveLastPullSuccess(_ date: Date) throws { try saveLastSuccess(date) }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Persist a successful pull's planned cursor. A nil cursor intentionally degrades
    /// the next operation to a full pull; failures preserve the previous cursor.
    public func applyPullOutcome(nextCursor: Date?, succeeded: Bool) throws {
        guard succeeded else { return }
        if let nextCursor {
            try saveLastPullSuccess(nextCursor)
        } else {
            try clear()
        }
    }
}
