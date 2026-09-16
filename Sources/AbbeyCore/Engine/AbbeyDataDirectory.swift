import Foundation

/// The one place that decides where Abbey's local data lives (DQN checkpoint and journal,
/// WDBX segments, rollback snapshots, pending pushes, CLI database and sync cursors).
///
/// Resolution order:
/// 1. `ABBEY_DATA_DIR`, when set and non-empty (`~` is expanded). Smoke scripts and
///    operators use this to point a process at a disposable or alternate directory.
/// 2. Inside a test host (XCTest or Swift Testing) with no override: a per-process
///    directory under the system temporary directory. A hand-run `swift test` must never
///    append experiences to, snapshot into, or rewrite the operator's real `~/.abbey`.
/// 3. Otherwise `~/.abbey`, which is byte-identical to the historical default.
public enum AbbeyDataDirectory: Sendable {
    public static let environmentKey = "ABBEY_DATA_DIR"

    /// The resolved directory. Does not create it.
    public static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTestHost: Bool = AbbeyDataDirectory.isTestHost,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        if isTestHost {
            return testHostFallback
        }
        return home.appendingPathComponent(".abbey", isDirectory: true)
    }

    /// The resolved directory, created (with intermediates) if missing.
    public static func ensure() throws -> URL {
        let dir = url()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A file inside the resolved directory. Does not create anything.
    public static func file(_ name: String) -> URL {
        url().appendingPathComponent(name, isDirectory: false)
    }

    /// Per-process fallback so parallel test processes never share state.
    static let testHostFallback: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "abbey-test-data-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )

    /// True when this process is a SwiftPM/Xcode test runner. The app, server and CLI
    /// never load an `.xctest` bundle, so this cannot redirect production data.
    public static let isTestHost: Bool = {
        let name = ProcessInfo.processInfo.processName
        if name == "xctest" || name == "swiftpm-testing-helper" { return true }
        if let argv0 = CommandLine.arguments.first, argv0.hasSuffix(".xctest") { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()
}
