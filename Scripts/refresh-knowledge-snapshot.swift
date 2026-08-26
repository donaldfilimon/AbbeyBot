#!/usr/bin/env swift
import CryptoKit
import Dispatch
import Foundation
import Security

struct Source {
    let id: String
    let title: String
    let repository: String
    let root: String
    let path: String
    let provenance: String
    let trustClassification: String
    let scopes: [String]
    let authority: Double
}

struct Entry: Codable, Equatable {
    var id: String
    var title: String
    var repository: String
    var revision: String
    var path: String
    var snapshotPath: String
    var bytes: Int
    var sha256: String
    var provenance: String
    var trustClassification: String
    var scopes: [String]
    var authority: Double
    var supersedes: [String]
}

struct Manifest: Codable {
    var formatVersion: Int
    var entries: [Entry]
    var aggregateDigest: String
}

private struct LegacyEntry: Decodable {
    var id: String
    var title: String
    var repository: String
    var revision: String
    var path: String
    var bytes: Int
    var sha256: String
    var provenance: String
    var scopes: [String]
    var authority: Double
    var supersedes: [String]

    var upgraded: Entry {
        Entry(id: id, title: title, repository: repository, revision: revision, path: path, snapshotPath: path, bytes: bytes,
              sha256: sha256, provenance: provenance, trustClassification: "", scopes: scopes,
              authority: authority, supersedes: supersedes)
    }
}
private struct LegacyManifest: Decodable { var entries: [LegacyEntry] }
private struct V2Entry: Decodable {
    var id: String
    var title: String
    var repository: String
    var revision: String
    var path: String
    var bytes: Int
    var sha256: String
    var provenance: String
    var trustClassification: String
    var scopes: [String]
    var authority: Double
    var supersedes: [String]

    var upgraded: Entry {
        Entry(id: id, title: title, repository: repository, revision: revision, path: path, snapshotPath: path,
              bytes: bytes, sha256: sha256, provenance: provenance, trustClassification: trustClassification,
              scopes: scopes, authority: authority, supersedes: supersedes)
    }
}
private struct V2Manifest: Decodable { var entries: [V2Entry] }

struct RefreshReport: Codable {
    var additions: [String]
    var removals: [String]
    var changedDigests: [String]
    var classificationChanges: [String]
    var unresolvedDrift: [String]
}

let arguments = Array(CommandLine.arguments.dropFirst())
let apply = arguments.contains("--apply")
let reviewedDigest: String? = {
    guard let index = arguments.firstIndex(of: "--reviewed-digest"), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}()
let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
let repositoryPath = repositoryRoot.path

let sources: [Source] = [
    .init(id: "abi-constitution", title: "Abbey System Constitution", repository: "abi", root: "/Users/donaldfilimon/dev/active/abi", path: "docs/superpowers/specs/2026-08-22-abbey-system-constitution.md", provenance: "measured", trustClassification: "constitutional", scopes: ["public", "authorization", "persona"], authority: 1),
    .init(id: "abi-identity", title: "Abbey Core Identity", repository: "abi", root: "/Users/donaldfilimon/dev/active/abi", path: "docs/spec/abbey-core-identity.mdx", provenance: "measured", trustClassification: "constitutional", scopes: ["public", "persona"], authority: 1),
    .init(id: "abi-personas", title: "Multi-Persona Technical Specification", repository: "abi", root: "/Users/donaldfilimon/dev/active/abi", path: "docs/spec/multi-persona-technical.mdx", provenance: "measured", trustClassification: "authoritative", scopes: ["public", "persona"], authority: 1),
    .init(id: "abi-wdbx-north-star", title: "WDBX North Star", repository: "abi", root: "/Users/donaldfilimon/dev/active/abi", path: "docs/spec/wdbx-north-star.mdx", provenance: "target", trustClassification: "explanatory", scopes: ["public", "wdbx", "knowledge"], authority: 0.95),
    .init(id: "abi-wdbx-conformance", title: "WDBX Conformance Gap Analysis", repository: "abi", root: "/Users/donaldfilimon/dev/active/abi", path: "docs/superpowers/specs/2026-08-22-wdbx-conformance-gap-analysis.md", provenance: "measured", trustClassification: "authoritative", scopes: ["public", "wdbx", "knowledge"], authority: 0.95),
    .init(id: "abbey-identity", title: "Abbey Identity", repository: "abbey", root: "/Users/donaldfilimon/dev/active/abbey", path: "docs/identity.md", provenance: "measured", trustClassification: "constitutional", scopes: ["public", "persona"], authority: 0.95),
    .init(id: "abbey-architecture", title: "Abbey Architecture", repository: "abbey", root: "/Users/donaldfilimon/dev/active/abbey", path: "docs/architecture.md", provenance: "measured", trustClassification: "authoritative", scopes: ["public", "architecture"], authority: 0.9),
    .init(id: "wdbx-readme", title: "Canonical WDBX", repository: "wdbx", root: "/Users/donaldfilimon/dev/active/wdbx", path: "README.md", provenance: "measured", trustClassification: "authoritative", scopes: ["public", "wdbx", "knowledge"], authority: 1),
    .init(id: "mlai-contracts", title: "MLAI Shared Contracts", repository: "mlai", root: "/Users/donaldfilimon/dev/active/mlai", path: "packages/contracts/README.md", provenance: "measured", trustClassification: "authoritative", scopes: ["public", "mlai", "quasar"], authority: 0.9),
    .init(id: "quasar-v1", title: "MLAI Quasar v1", repository: "mlai", root: "/Users/donaldfilimon/dev/active/mlai", path: "apps/quasar/README.md", provenance: "measured", trustClassification: "compatibility", scopes: ["public", "mlai", "quasar"], authority: 0.95),
    .init(id: "quasar-design", title: "MLAI Quasar Design", repository: "mlai", root: "/Users/donaldfilimon/dev/active/mlai", path: "apps/quasar/docs/superpowers/specs/2026-08-19-quasar-v1-design.md", provenance: "target", trustClassification: "explanatory", scopes: ["public", "mlai", "quasar"], authority: 0.85),
    .init(id: "abbey-contract-readme", title: "Vendored Abbey Contract Corpus", repository: "AbbeyBot", root: repositoryPath, path: "Contracts/Abbey/corpus/README.md", provenance: "measured", trustClassification: "authoritative", scopes: ["public", "authorization", "consent", "contracts"], authority: 1),
    .init(id: "abbey-contract-compatibility", title: "Abbey Contract Compatibility", repository: "AbbeyBot", root: repositoryPath, path: "Contracts/Abbey/corpus/compatibility.md", provenance: "measured", trustClassification: "compatibility", scopes: ["public", "authorization", "consent", "contracts"], authority: 1),
    .init(id: "abbey-contract-manifest", title: "Abbey Contract Artifact Manifest", repository: "AbbeyBot", root: repositoryPath, path: "Contracts/Abbey/corpus/manifest.json", provenance: "measured", trustClassification: "authoritative", scopes: ["public", "authorization", "consent", "contracts"], authority: 1),
]

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func store(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func runData(_ arguments: [String], directory: String) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()

    // Drain both finite pipe buffers while the child is running. Keeping the
    // streams separate prevents a git warning on stderr from corrupting source
    // bytes returned by a successful `git show`.
    let outputData = LockedData()
    let errorData = LockedData()
    let drains = DispatchGroup()
    drains.enter()
    DispatchQueue.global().async {
        outputData.store(standardOutput.fileHandleForReading.readDataToEndOfFile())
        drains.leave()
    }
    drains.enter()
    DispatchQueue.global().async {
        errorData.store(standardError.fileHandleForReading.readDataToEndOfFile())
        drains.leave()
    }
    process.waitUntilExit()
    drains.wait()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: errorData.load().suffix(4_096), as: UTF8.self)
        throw NSError(domain: "AbbeyBot.KnowledgeRefresh", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
    }
    return outputData.load()
}

func revision(for root: String) throws -> String {
    String(decoding: try runData(["git", "rev-parse", "HEAD"], directory: root), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizedCommittedData(source: Source, revision: String) throws -> Data {
    let committed = try runData(["git", "show", "\(revision):\(source.path)"], directory: source.root)
    guard var text = String(data: committed, encoding: .utf8) else {
        throw NSError(domain: "AbbeyBot.KnowledgeRefresh", code: 2, userInfo: [NSLocalizedDescriptionKey: "Non-UTF-8 allowlisted source: \(source.repository):\(source.path)"])
    }
    text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    if !text.hasSuffix("\n") { text.append("\n") }
    return Data(text.utf8)
}

let output = repositoryRoot.appendingPathComponent("Sources/AbbeyCore/Resources/KnowledgeSnapshot", isDirectory: true)
let candidate = repositoryRoot.appendingPathComponent(".build/knowledge-snapshot-candidate", isDirectory: true)
if FileManager.default.fileExists(atPath: candidate.path) { try FileManager.default.removeItem(at: candidate) }
try FileManager.default.createDirectory(at: candidate.appendingPathComponent("documents", isDirectory: true), withIntermediateDirectories: true)

var entries: [Entry] = []
for source in sources {
    let sourceRevision = try revision(for: source.root)
    let data = try normalizedCommittedData(source: source, revision: sourceRevision)
    let storedPath = "documents/\(source.id).md"
    try data.write(to: candidate.appendingPathComponent(storedPath), options: .atomic)
    entries.append(.init(
        id: source.id,
        title: source.title,
        repository: source.repository,
        revision: sourceRevision,
        path: source.path,
        snapshotPath: storedPath,
        bytes: data.count,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        provenance: source.provenance,
        trustClassification: source.trustClassification,
        scopes: source.scopes.sorted(),
        authority: source.authority,
        supersedes: []
    ))
}
entries.sort { $0.id < $1.id }
let canonical = entries.map {
    [$0.id, $0.title, $0.repository, $0.revision, $0.path, $0.snapshotPath, String($0.bytes), $0.sha256,
     $0.provenance, $0.trustClassification, $0.scopes.joined(separator: ","),
     String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0.authority),
     $0.supersedes.joined(separator: ",")]
        .joined(separator: "\t")
}.joined(separator: "\n")
let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
let manifest = Manifest(formatVersion: 3, entries: entries, aggregateDigest: digest)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(manifest).write(to: candidate.appendingPathComponent("manifest.json"), options: .atomic)

let oldData = try? Data(contentsOf: output.appendingPathComponent("manifest.json"))
let oldEntries: [Entry]
if let oldData, let decoded = try? JSONDecoder().decode(Manifest.self, from: oldData) {
    oldEntries = decoded.entries
} else if let oldData, let decoded = try? JSONDecoder().decode(V2Manifest.self, from: oldData) {
    oldEntries = decoded.entries.map(\.upgraded)
} else if let oldData, let decoded = try? JSONDecoder().decode(LegacyManifest.self, from: oldData) {
    oldEntries = decoded.entries.map(\.upgraded)
} else {
    oldEntries = []
}
let oldByID = Dictionary(uniqueKeysWithValues: oldEntries.map { ($0.id, $0) })
let newByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
let report = RefreshReport(
    additions: newByID.keys.filter { oldByID[$0] == nil }.sorted(),
    removals: oldByID.keys.filter { newByID[$0] == nil }.sorted(),
    changedDigests: newByID.keys.filter { oldByID[$0]?.sha256 != nil && oldByID[$0]?.sha256 != newByID[$0]?.sha256 }.sorted(),
    classificationChanges: newByID.keys.filter {
        guard let old = oldByID[$0], let new = newByID[$0] else { return false }
        return old.provenance != new.provenance || old.trustClassification != new.trustClassification || old.scopes != new.scopes || old.authority != new.authority
    }.sorted(),
    unresolvedDrift: newByID.keys.filter {
        guard let old = oldByID[$0], let new = newByID[$0] else { return false }
        return old.path != new.path || old.snapshotPath != new.snapshotPath || (old.revision != new.revision && old.sha256 == new.sha256)
    }.sorted()
)
try encoder.encode(report).write(to: candidate.appendingPathComponent("refresh-report.json"), options: .atomic)
print(String(decoding: try encoder.encode(report), as: UTF8.self))
print("KNOWLEDGE_CANDIDATE_DIGEST \(digest)")
print("KNOWLEDGE_CANDIDATE_PATH \(candidate.path)")

guard apply else {
    print("Review the manifest and document diff, then run: Scripts/refresh-knowledge-snapshot.swift --apply --reviewed-digest \(digest)")
    exit(EXIT_SUCCESS)
}
guard reviewedDigest == digest else {
    throw NSError(domain: "AbbeyBot.KnowledgeRefresh", code: 3, userInfo: [NSLocalizedDescriptionKey: "--reviewed-digest must exactly match the generated candidate digest"])
}

func reviewedPublicKey(at snapshotRoot: URL) throws -> Data? {
    let url = snapshotRoot.appendingPathComponent("public-key.base64")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw NSError(
            domain: "AbbeyBot.KnowledgeRefresh",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Existing knowledge public key is not a regular file; refusing snapshot replacement"]
        )
    }
    let encoded = try String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let decoded = Data(base64Encoded: encoded), decoded.count == 32 else {
        throw NSError(
            domain: "AbbeyBot.KnowledgeRefresh",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Existing knowledge public key is malformed; refusing snapshot replacement"]
        )
    }
    return decoded
}

let existingPublicKey = try reviewedPublicKey(at: output)

let service = "AbbeyBot.KnowledgeSnapshot.Ed25519"
let account = NSUserName()
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecReturnData as String: true,
]
var item: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &item)
let key: Curve25519.Signing.PrivateKey
if status == errSecSuccess {
    guard let data = item as? Data else {
        throw NSError(
            domain: "AbbeyBot.KnowledgeRefresh",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Knowledge signing keychain item did not contain key data"]
        )
    }
    key = try .init(rawRepresentation: data)
    if let existingPublicKey,
       existingPublicKey != key.publicKey.rawRepresentation {
        throw NSError(
            domain: "AbbeyBot.KnowledgeRefresh",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Knowledge signing key does not match the reviewed snapshot public key; explicit public-key pin rotation is required"]
        )
    }
} else if status == errSecItemNotFound {
    guard existingPublicKey == nil else {
        throw NSError(
            domain: "AbbeyBot.KnowledgeRefresh",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "Knowledge signing key is unavailable; refusing to replace a snapshot signed by the reviewed key. Restore the Keychain item or perform an explicit public-key pin rotation."]
        )
    }
    key = .init()
    let add: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: key.rawRepresentation,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
} else {
    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
}
try key.publicKey.rawRepresentation.base64EncodedData().write(to: candidate.appendingPathComponent("public-key.base64"), options: .atomic)
try key.signature(for: Data(digest.utf8)).base64EncodedData().write(to: candidate.appendingPathComponent("signature.base64"), options: .atomic)
try? FileManager.default.removeItem(at: candidate.appendingPathComponent("refresh-report.json"))

_ = try FileManager.default.replaceItemAt(output, withItemAt: candidate)
print("KNOWLEDGE_SNAPSHOT_SIGNED \(entries.count) \(digest)")
