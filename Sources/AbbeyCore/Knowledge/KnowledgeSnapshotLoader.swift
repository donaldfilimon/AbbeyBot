import Crypto
import Foundation

public enum KnowledgeSnapshotLoader {
    /// SHA-256 of the reviewed Ed25519 public key. The key is intentionally
    /// anchored in code rather than trusted merely because it sits beside the
    /// signature it verifies. Rotation therefore requires a visible source
    /// change in addition to a newly signed snapshot.
    private static let trustedPublicKeyDigest =
        "809d05dd96e916cbf9034d87e323dddf9eeeb568bc0478913b16594b785b77ce"

    public static func loadVerified() throws -> [KnowledgeDocument] {
        try loadVerified(bundle: .module)
    }

    public static func loadVerified(bundle: Bundle) throws -> [KnowledgeDocument] {
        guard let root = bundle.url(forResource: "KnowledgeSnapshot", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try loadVerified(snapshotRoot: root)
    }

    public static func bundledSnapshotURL() throws -> URL {
        guard let root = Bundle.module.url(forResource: "KnowledgeSnapshot", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }

    public static func loadVerified(snapshotRoot root: URL) throws -> [KnowledgeDocument] {
        let root = root.standardizedFileURL
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(KnowledgeManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.formatVersion == 3 else { throw KnowledgeSnapshotError.unsupportedFormat(manifest.formatVersion) }
        let publicKey = try decodeBase64File(root.appendingPathComponent("public-key.base64"))
        let signature = try decodeBase64File(root.appendingPathComponent("signature.base64"))
        let publicKeyDigest = SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }.joined()
        guard publicKeyDigest == trustedPublicKeyDigest else {
            throw KnowledgeSnapshotError.untrustedPublicKey
        }
        try KnowledgeSnapshotVerifier.verify(manifest: manifest, publicKey: publicKey, signature: signature)

        let expected = Set(manifest.entries.map(\.snapshotPath))
        let documentRoot = root.appendingPathComponent("documents", isDirectory: true)
        let documentURLs = try FileManager.default.contentsOfDirectory(
            at: documentRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        var discovered = Set<String>()
        for url in documentURLs {
            let relative = "documents/" + url.lastPathComponent
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw KnowledgeSnapshotError.unexpectedSource(relative)
            }
            discovered.insert(relative)
        }
        if let missing = expected.subtracting(discovered).sorted().first { throw KnowledgeSnapshotError.missingSource(missing) }
        if let extra = discovered.subtracting(expected).sorted().first { throw KnowledgeSnapshotError.unexpectedSource(extra) }

        return try manifest.entries.map { entry in
            let components = entry.snapshotPath.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2,
                  components[0] == "documents",
                  !components[1].isEmpty,
                  components[1] != ".",
                  components[1] != ".."
            else { throw CocoaError(.fileReadInvalidFileName) }
            let url = root.appendingPathComponent(entry.snapshotPath).standardizedFileURL
            guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw KnowledgeSnapshotError.unexpectedSource(entry.snapshotPath)
            }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == entry.bytes, digest == entry.sha256 else {
                throw KnowledgeSnapshotError.aggregateDigestMismatch(expected: entry.sha256, actual: digest)
            }
            guard let content = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return KnowledgeDocument(
                id: entry.id,
                title: entry.title,
                content: content,
                sourceRepository: entry.repository,
                sourceRevision: entry.revision,
                sourcePath: entry.path,
                contentDigest: entry.sha256,
                scopes: Set(entry.scopes),
                provenance: entry.provenance,
                trustClassification: entry.trustClassification,
                authority: entry.authority,
                supersedes: Set(entry.supersedes)
            )
        }
    }

    private static func decodeBase64File(_ url: URL) throws -> Data {
        let raw = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: raw) else { throw KnowledgeSnapshotError.malformedSignature }
        return data
    }
}
