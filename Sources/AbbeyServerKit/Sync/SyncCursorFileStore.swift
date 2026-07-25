import Foundation

/// File-backed unix-epoch cursor for CLI pullers/pushers without UserDefaults. One line,
/// seconds since 1970. Missing or unparseable content degrades to nil — a full sync —
/// mirroring the desktop's `SyncCursorStore` semantics (stamp at *start*, persist only after
/// the operation succeeds). Pull and push use separate default files so one cannot advance
/// the other.
public struct SyncCursorFileStore: Sendable {
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
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        guard let epoch = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), epoch > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Alias kept for call sites that named the pull-side API explicitly.
    public func loadLastPullSuccess() -> Date? { loadLastSuccess() }

    public func saveLastSuccess(_ date: Date) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try String(date.timeIntervalSince1970).write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Alias kept for call sites that named the pull-side API explicitly.
    public func saveLastPullSuccess(_ date: Date) throws { try saveLastSuccess(date) }
}
