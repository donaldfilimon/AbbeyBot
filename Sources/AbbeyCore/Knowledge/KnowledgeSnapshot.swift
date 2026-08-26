import Crypto
import Foundation

public struct KnowledgeManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var title: String = ""
        public var repository: String
        public var revision: String
        /// Authoritative repository-relative source path.
        public var path: String
        /// Package-resource-relative projection path.
        public var snapshotPath: String = ""
        public var bytes: Int
        public var sha256: String
        public var provenance: KnowledgeProvenance
        public var trustClassification: KnowledgeTrustClassification = .authoritative
        public var scopes: [String]
        public var authority: Double = 0.5
        public var supersedes: [String] = []
    }

    public var formatVersion: Int
    public var entries: [Entry]
    public var aggregateDigest: String
}

public enum KnowledgeSnapshotError: Error, LocalizedError, Equatable {
    case malformedPublicKey
    case untrustedPublicKey
    case malformedSignature
    case invalidSignature
    case aggregateDigestMismatch(expected: String, actual: String)
    case duplicateIdentifier(String)
    case unsupportedFormat(Int)
    case missingSource(String)
    case unexpectedSource(String)

    public var errorDescription: String? {
        switch self {
        case .malformedPublicKey: return "Knowledge snapshot public key is malformed."
        case .untrustedPublicKey: return "Knowledge snapshot public key is not the reviewed trust anchor."
        case .malformedSignature: return "Knowledge snapshot signature is malformed."
        case .invalidSignature: return "Knowledge snapshot signature is invalid."
        case .aggregateDigestMismatch(let expected, let actual):
            return "Knowledge aggregate digest mismatch: expected \(expected), got \(actual)."
        case .duplicateIdentifier(let id): return "Knowledge manifest contains duplicate id \(id)."
        case .unsupportedFormat(let version): return "Knowledge manifest format \(version) is unsupported."
        case .missingSource(let path): return "Knowledge snapshot source is missing: \(path)."
        case .unexpectedSource(let path): return "Knowledge snapshot contains an unmanifested source: \(path)."
        }
    }
}

public enum KnowledgeSnapshotVerifier {
    private static let canonicalLocale = Locale(identifier: "en_US_POSIX")
    public static func drift(from current: KnowledgeManifest, to candidate: KnowledgeManifest) -> KnowledgeRefreshReport {
        let old = Dictionary(uniqueKeysWithValues: current.entries.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: candidate.entries.map { ($0.id, $0) })
        return KnowledgeRefreshReport(
            additions: new.keys.filter { old[$0] == nil }.sorted(),
            removals: old.keys.filter { new[$0] == nil }.sorted(),
            changedDigests: new.keys.filter { old[$0] != nil && old[$0]?.sha256 != new[$0]?.sha256 }.sorted(),
            classificationChanges: new.keys.filter { id in
                guard let lhs = old[id], let rhs = new[id] else { return false }
                return lhs.provenance != rhs.provenance
                    || lhs.trustClassification != rhs.trustClassification
                    || lhs.scopes.sorted() != rhs.scopes.sorted()
                    || lhs.authority != rhs.authority
            }.sorted(),
            unresolvedDrift: new.keys.filter { id in
                guard let lhs = old[id], let rhs = new[id] else { return false }
                return (lhs.revision != rhs.revision && lhs.sha256 == rhs.sha256)
                    || lhs.path != rhs.path
                    || lhs.snapshotPath != rhs.snapshotPath
            }.sorted()
        )
    }

    public static func canonicalDigest(entries: [KnowledgeManifest.Entry]) throws -> String {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.id == rhs.id { return lhs.path < rhs.path }
            return lhs.id < rhs.id
        }
        var seen = Set<String>()
        for entry in sorted where !seen.insert(entry.id).inserted {
            throw KnowledgeSnapshotError.duplicateIdentifier(entry.id)
        }
        let lines = sorted.map {
            [$0.id, $0.title, $0.repository, $0.revision, $0.path, $0.snapshotPath, String($0.bytes), $0.sha256,
             $0.provenance.rawValue, $0.trustClassification.rawValue, $0.scopes.sorted().joined(separator: ","),
             String(format: "%.6f", locale: canonicalLocale, $0.authority),
             $0.supersedes.sorted().joined(separator: ",")]
                .joined(separator: "\t")
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(manifest: KnowledgeManifest, publicKey: Data, signature: Data) throws {
        let actual = try canonicalDigest(entries: manifest.entries)
        guard actual == manifest.aggregateDigest else {
            throw KnowledgeSnapshotError.aggregateDigestMismatch(expected: manifest.aggregateDigest, actual: actual)
        }
        let key: Curve25519.Signing.PublicKey
        do { key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey) }
        catch { throw KnowledgeSnapshotError.malformedPublicKey }
        guard signature.count == 64 else { throw KnowledgeSnapshotError.malformedSignature }
        guard key.isValidSignature(signature, for: Data(actual.utf8)) else {
            throw KnowledgeSnapshotError.invalidSignature
        }
    }
}
