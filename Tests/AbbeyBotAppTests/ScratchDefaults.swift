import Foundation

/// A `UserDefaults` suite owned by one test, stored outside `~/Library/Preferences`.
///
/// A UUID-named `UserDefaults(suiteName:)` leaks: `removePersistentDomain(forName:)` empties
/// the suite but leaves a 42-byte plist behind, so every run adds one more entry to
/// `defaults domains` (thousands had accumulated by 2026-09-16). On Darwin an absolute-path
/// suite name keeps the plist inside a temporary directory that `remove()` deletes whole.
/// Call `remove()` from a `defer`. `AbbeyCoreTests` carries the original of this type.
struct ScratchDefaults {
    let defaults: UserDefaults
    private let suiteName: String
    private let directory: URL?

    init(_ label: String) throws {
        #if canImport(Darwin)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = directory.appendingPathComponent(label).path
        self.directory = directory
        #else
        suiteName = "\(label).\(UUID().uuidString)"
        directory = nil
        #endif
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: suiteName])
        }
        self.defaults = defaults
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
