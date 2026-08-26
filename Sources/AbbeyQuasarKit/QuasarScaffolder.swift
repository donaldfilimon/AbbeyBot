import Crypto
import Foundation

private struct QuasarTemplateManifest: Decodable {
    var formatVersion: Int
    var sourceRepository: String
    var sourceRevision: String
    var stack: [String: String]
    var files: [String: String]
}

public struct QuasarScaffolder: Sendable {
    public let templateURL: URL
    private let manifest: QuasarTemplateManifest

    public init(templateURL: URL? = nil) throws {
        if let templateURL {
            self.templateURL = templateURL
            self.manifest = try Self.manifest(for: templateURL)
        }
        else {
            guard let bundled = Bundle.module.url(forResource: "next-site", withExtension: nil) else {
                throw QuasarError.processFailed("bundled next-site template is missing")
            }
            self.templateURL = bundled
            guard let manifestURL = Bundle.module.url(forResource: "next-site.manifest.json", withExtension: nil) else {
                throw QuasarError.processFailed("bundled next-site manifest is missing")
            }
            self.manifest = try JSONDecoder().decode(QuasarTemplateManifest.self, from: Data(contentsOf: manifestURL))
        }
        try Self.verify(templateURL: self.templateURL, manifest: self.manifest)
    }

    private static func manifest(for templateURL: URL) throws -> QuasarTemplateManifest {
        let url = templateURL.deletingLastPathComponent().appendingPathComponent("next-site.manifest.json")
        return try JSONDecoder().decode(QuasarTemplateManifest.self, from: Data(contentsOf: url))
    }

    private static func verify(templateURL: URL, manifest: QuasarTemplateManifest) throws {
        guard manifest.formatVersion == 1,
              manifest.stack["react"] == "React 19",
              manifest.stack["framework"] == "Next.js 15",
              manifest.stack["runtime"] == "Bun" else {
            throw QuasarError.processFailed("template manifest stack is not qualified")
        }
        // QuasarPathGuard normalizes filesystem aliases such as macOS
        // /var -> /private/var before enumeration.
        let guarder = try QuasarPathGuard(root: templateURL)
        let canonicalTemplateURL = guarder.root
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalTemplateURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw QuasarError.processFailed("template cannot be enumerated") }
        var discovered = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw QuasarError.processFailed("template contains a symlink") }
            if values.isRegularFile == true {
                discovered.insert(String(url.path.dropFirst(canonicalTemplateURL.path.count + 1)))
            }
        }
        guard discovered == Set(manifest.files.keys) else {
            throw QuasarError.processFailed("template files differ from pinned manifest")
        }
        for (path, expected) in manifest.files {
            let data = try Data(contentsOf: guarder.resolve(path, permitMissingLeaf: false))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw QuasarError.processFailed("template digest mismatch: \(path)") }
        }
    }

    public func scaffold(at destination: URL, installDependencies: Bool = false) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw QuasarError.invalidInput("site directory already exists")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: templateURL, to: destination)
        if installDependencies {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["bun", "install", "--frozen-lockfile"]
            process.currentDirectoryURL = destination
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run()
            // Drain while Bun is running so verbose install output cannot fill
            // the finite pipe buffer and deadlock the child before it exits.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw QuasarError.processFailed(Self.redact(String(decoding: data.prefix(8_192), as: UTF8.self)))
            }
        }
    }

    private static func redact(_ value: String) -> String {
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
