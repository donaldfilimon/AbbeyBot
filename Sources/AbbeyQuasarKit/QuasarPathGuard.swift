import Foundation

public struct QuasarPathGuard: Sendable {
    public static let maximumFileBytes = 512 * 1_024
    public static let blockedComponents: Set<String> = [".git", "node_modules", ".next"]
    public let root: URL

    public init(root: URL) throws {
        let standardized = root.standardizedFileURL
        try FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
        let canonicalPath = try standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
            ?? standardized.path
        self.root = URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    public func resolve(_ relativePath: String, permitMissingLeaf: Bool = true) throws -> URL {
        guard !relativePath.isEmpty,
              relativePath.utf8.count <= 1_024,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0")
        else {
            throw QuasarError.pathRejected("path must be non-empty and relative")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(""),
              !components.contains(".."),
              !components.contains("."),
              components.allSatisfy({ !$0.utf8.isEmpty && $0.utf8.count <= 255 }),
              !components.contains(where: { Self.blockedComponents.contains($0.lowercased()) })
        else {
            throw QuasarError.pathRejected("blocked path component")
        }
        let candidate = root.appendingPathComponent(relativePath)
        let parentPath = try Self.canonicalPath(candidate.deletingLastPathComponent())
        try Self.requireAllowedCanonicalPath(parentPath, root: root.path)
        if FileManager.default.fileExists(atPath: candidate.path) {
            let resolvedPath = try Self.canonicalPath(candidate)
            try Self.requireAllowedCanonicalPath(resolvedPath, root: root.path)
            return URL(fileURLWithPath: resolvedPath)
        }
        guard permitMissingLeaf else { throw QuasarError.notFound }
        // Resolve existing parent aliases before returning a missing leaf. This
        // gives duplicate-destination checks one canonical spelling even when
        // an in-root symlink points at another in-root directory.
        return URL(fileURLWithPath: parentPath, isDirectory: true)
            .appendingPathComponent(candidate.lastPathComponent)
    }

    public func read(_ relativePath: String) throws -> String {
        let url = try resolve(relativePath, permitMissingLeaf: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= Self.maximumFileBytes else { throw QuasarError.fileTooLarge }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func list() throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var output: [String] = []
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let pieces = relative.split(separator: "/").map { $0.lowercased() }
            if pieces.contains(where: Self.blockedComponents.contains) { enumerator.skipDescendants(); continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true { output.append(relative) }
        }
        return output.sorted()
    }

    private static func canonicalPath(_ url: URL) throws -> String {
        let fileManager = FileManager.default
        var existing = url
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { throw QuasarError.pathRejected("path has no existing ancestor") }
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        let resolved = existing.resolvingSymlinksInPath()
        let base = try resolved.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? resolved.path
        return missingComponents.reduce(base) { partial, component in
            (partial as NSString).appendingPathComponent(component)
        }
    }

    private static func isContained(_ candidate: String, by root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func requireAllowedCanonicalPath(_ candidate: String, root: String) throws {
        guard isContained(candidate, by: root) else {
            throw QuasarError.pathRejected("path escapes site root")
        }
        let relative = candidate == root ? "" : String(candidate.dropFirst(root.count + 1))
        let components = relative.split(separator: "/").map { $0.lowercased() }
        guard !components.contains(where: blockedComponents.contains) else {
            throw QuasarError.pathRejected("canonical path contains a blocked component")
        }
    }
}
