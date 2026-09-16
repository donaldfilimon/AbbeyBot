import AbbeyCore
import Foundation

/// File-backed unix-epoch cursor for CLI pullers/pushers without UserDefaults. One line,
/// seconds since 1970. Missing or unparseable content degrades to nil — a full sync —
/// mirroring the desktop's `SyncCursorStore` semantics (pull start is the upper bound, a full
/// page may select an earlier server boundary, and only success persists). Pull and push use
/// separate default files so one cannot advance the other; CLI push additionally stores
/// message/memory progress in sidecars.
public struct SyncCursorFileStore: Sendable {
    public enum Stream: String, Sendable {
        case messages
        case memories
    }

    public let fileURL: URL

    /// Default pull cursor: `~/.abbey/cli-sync-cursor`.
    public static func defaultURL() -> URL {
        AbbeyDataDirectory.file("cli-sync-cursor")
    }

    /// Default push cursor: `~/.abbey/cli-sync-push-cursor` (independent of the pull cursor).
    public static func defaultPushURL() -> URL {
        AbbeyDataDirectory.file("cli-sync-push-cursor")
    }

    public static func namespacedPullURL(endpoint: String) -> URL {
        namespaced(defaultURL(), endpoint: endpoint)
    }

    public static func namespacedPushURL(endpoint: String) -> URL {
        namespaced(defaultPushURL(), endpoint: endpoint)
    }

    private static func namespaced(_ url: URL, endpoint: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).\(SyncEndpointIdentity.storageKey(for: endpoint))",
            isDirectory: false
        )
    }

    public init(fileURL: URL = SyncCursorFileStore.defaultURL()) {
        self.fileURL = fileURL
    }

    public func loadLastSuccess() -> Date? {
        loadCursor(at: fileURL)
    }

    /// Loads v2 per-entity pull progress. A legacy one-line epoch is expanded across all
    /// streams and is rewritten as JSON after the next successful pull.
    public func loadPullCursors() -> SyncPullCursorSet {
        guard let data = try? Data(contentsOf: fileURL) else { return SyncPullCursorSet() }
        if let decoded = try? JSONDecoder().decode(SyncPullCursorSet.self, from: data) {
            return decoded
        }
        guard let raw = String(data: data, encoding: .utf8),
              let epoch = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              epoch > 0
        else { return SyncPullCursorSet() }
        return SyncPullCursorSet(legacyTimestamp: Date(timeIntervalSince1970: epoch))
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
    public func loadLastPullSuccess() -> Date? {
        loadPullCursors().earliestChangedAt ?? loadLastSuccess()
    }

    public func saveLastSuccess(_ date: Date) throws {
        try save(date, at: fileURL)
    }

    public func savePullCursors(_ cursors: SyncPullCursorSet) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cursors)
        try data.write(to: fileURL, options: .atomic)
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


    public func applyPullOutcome(nextCursors: SyncPullCursorSet, succeeded: Bool) throws {
        guard succeeded else { return }
        try savePullCursors(nextCursors)
    }
}
