import Foundation

/// File-backed `?since=` cursor for pullers without UserDefaults (the CLI). One line, unix
/// epoch seconds. Missing or unparseable content degrades to nil — a full pull — mirroring
/// the desktop's `SyncCursorStore` semantics (stamp at pull *start*, persist only after the
/// pull succeeds).
public struct SyncCursorFileStore: Sendable {
    public let fileURL: URL

    /// Default location: `~/.abbey/cli-sync-cursor`.
    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".abbey", isDirectory: true)
            .appendingPathComponent("cli-sync-cursor", isDirectory: false)
    }

    public init(fileURL: URL = SyncCursorFileStore.defaultURL()) {
        self.fileURL = fileURL
    }

    public func loadLastPullSuccess() -> Date? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        guard let epoch = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), epoch > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: epoch)
    }

    public func saveLastPullSuccess(_ date: Date) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try String(date.timeIntervalSince1970).write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
