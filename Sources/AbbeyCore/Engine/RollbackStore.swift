import Foundation

/// Stateful rollback for Abbey-managed files under `~/.abbey` (Phase 2).
/// Snapshots copy into `~/.abbey/rollback/<name>/` before risky writes; `restore` replaces
/// the live file from a named snapshot or from a sibling `*.bak`.
public enum RollbackStore: Sendable {
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case pathNotManaged(URL)
        case missingSnapshot(String)
        case missingBackup(URL)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .pathNotManaged(let url):
                return "Rollback refused: \(url.path) is outside ~/.abbey"
            case .missingSnapshot(let name):
                return "Rollback snapshot not found: \(name)"
            case .missingBackup(let url):
                return "No .bak for \(url.lastPathComponent)"
            case .io(let detail):
                return "Rollback I/O: \(detail)"
            }
        }
    }

    public static func abbeyHome() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".abbey", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func rollbackRoot() throws -> URL {
        let root = try abbeyHome().appendingPathComponent("rollback", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static func isManaged(_ url: URL) throws -> Bool {
        let abbey = try abbeyHome().resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == abbey || path.hasPrefix(abbey + "/")
    }

    /// Copy `url` into `~/.abbey/rollback/<name>/<filename>` (creates dirs).
    @discardableResult
    public static func snapshot(file url: URL, as name: String) throws -> URL {
        guard try isManaged(url) else { throw Error.pathNotManaged(url) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw Error.io("source missing: \(url.path)")
        }
        let destDir = try rollbackRoot().appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        do {
            try fm.copyItem(at: url, to: dest)
        } catch {
            throw Error.io(error.localizedDescription)
        }
        return dest
    }

    /// Replace live `url` with contents from snapshot `name`.
    public static func restore(file url: URL, fromSnapshot name: String) throws {
        guard try isManaged(url) else { throw Error.pathNotManaged(url) }
        let source = try rollbackRoot()
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent, isDirectory: false)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw Error.missingSnapshot(name)
        }
        try replace(live: url, with: source)
    }

    /// Replace live `url` from sibling `url.bak` when present.
    public static func restoreFromBak(_ url: URL) throws {
        guard try isManaged(url) else { throw Error.pathNotManaged(url) }
        let bak = url.appendingPathExtension("bak")
        guard FileManager.default.fileExists(atPath: bak.path) else {
            throw Error.missingBackup(url)
        }
        try replace(live: url, with: bak)
    }

    private static func replace(live: URL, with source: URL) throws {
        let fm = FileManager.default
        let dir = live.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = live.appendingPathExtension("rollback-tmp")
        do {
            if fm.fileExists(atPath: tmp.path) {
                try fm.removeItem(at: tmp)
            }
            try fm.copyItem(at: source, to: tmp)
            if fm.fileExists(atPath: live.path) {
                try fm.removeItem(at: live)
            }
            try fm.moveItem(at: tmp, to: live)
        } catch let error as Error {
            throw error
        } catch {
            throw Error.io(error.localizedDescription)
        }
    }
}

extension DQNCheckpointStore {
    /// Restore checkpoint from `*.bak` via `RollbackStore` (managed `~/.abbey` only).
    public static func restoreFromBak(at url: URL) throws {
        try RollbackStore.restoreFromBak(url)
    }
}
