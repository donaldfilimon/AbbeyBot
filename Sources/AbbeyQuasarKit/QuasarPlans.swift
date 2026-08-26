import Crypto
import Foundation

public struct QuasarReadPlan: Codable, Equatable, Sendable {
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

public enum QuasarMutationOperation: Codable, Equatable, Sendable {
    case write(path: String, content: String)
    case remove(path: String)

    private enum CodingKeys: String, CodingKey { case type, path, content }
    private enum Kind: String, Codable { case write, remove }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        switch try box.decode(Kind.self, forKey: .type) {
        case .write: self = .write(path: try box.decode(String.self, forKey: .path), content: try box.decode(String.self, forKey: .content))
        case .remove: self = .remove(path: try box.decode(String.self, forKey: .path))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .write(let path, let content): try box.encode(Kind.write, forKey: .type); try box.encode(path, forKey: .path); try box.encode(content, forKey: .content)
        case .remove(let path): try box.encode(Kind.remove, forKey: .type); try box.encode(path, forKey: .path)
        }
    }
}

public struct QuasarMutationPlan: Codable, Equatable, Sendable {
    public var summary: String
    public var operations: [QuasarMutationOperation]
    public var idempotencyKey: String
    public init(summary: String, operations: [QuasarMutationOperation], idempotencyKey: String) {
        self.summary = summary; self.operations = operations; self.idempotencyKey = idempotencyKey
    }
}

public struct QuasarMutationReceipt: Codable, Equatable, Sendable {
    public var siteID: String
    public var idempotencyKey: String
    public var planDigest: String
    public var changedPaths: [String]
    public var rollbackDirectory: String
}

public struct QuasarRollbackReceipt: Codable, Equatable, Sendable {
    public var planDigest: String
    public var restoredPaths: [String]
    public var rolledBackAt: Date
}

private struct QuasarRollbackManifest: Codable {
    struct Entry: Codable {
        var path: String
        var existedBefore: Bool
        var byteCount: Int
        var sha256: String?
    }
    var siteID: String
    var planDigest: String
    var entries: [Entry]
}

public struct QuasarMutationChange: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case write, remove }
    public var id: String { "\(kind.rawValue):\(path)" }
    public var kind: Kind
    public var path: String
    public var byteCount: Int

    public init(kind: Kind, path: String, byteCount: Int) {
        self.kind = kind
        self.path = path
        self.byteCount = byteCount
    }
}

/// A content-bounded description that is safe to show in authorization surfaces.
/// Generated source remains inside the coordinator until the operator approves it.
public struct QuasarMutationPreview: Codable, Equatable, Sendable {
    public var siteID: String
    public var summary: String
    public var planDigest: String
    public var changes: [QuasarMutationChange]
    public var totalWriteBytes: Int
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        siteID: String,
        summary: String,
        planDigest: String,
        changes: [QuasarMutationChange],
        totalWriteBytes: Int,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.siteID = siteID
        self.summary = summary
        self.planDigest = planDigest
        self.changes = changes
        self.totalWriteBytes = totalWriteBytes
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public actor QuasarMutationExecutor {
    private struct CompletionKey: Hashable, Sendable {
        var siteID: String
        var idempotencyKey: String
    }

    public struct Limits: Sendable {
        public var maximumOperations = 32
        public var maximumFileBytes = QuasarPathGuard.maximumFileBytes
        public var maximumTotalBytes = 2 * 1_024 * 1_024
        public init() {}
    }
    private let limits: Limits
    private var completed: [CompletionKey: QuasarMutationReceipt] = [:]
    public init(limits: Limits = .init()) { self.limits = limits }

    public func validate(
        _ plan: QuasarMutationPlan,
        siteID: String,
        siteRoot: URL,
        createdAt: Date = Date(),
        lifetime: Duration = .seconds(300)
    ) throws -> QuasarMutationPreview {
        let siteID = try Self.checkedSiteID(siteID)
        guard !plan.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuasarError.malformedPlan("idempotency key is required")
        }
        guard (1...limits.maximumOperations).contains(plan.operations.count) else {
            throw QuasarError.budgetExceeded("operation count")
        }
        guard !plan.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              plan.summary.utf8.count <= 2_048 else {
            throw QuasarError.malformedPlan("summary must contain 1...2048 bytes")
        }

        let guarder = try QuasarPathGuard(root: siteRoot)
        var seen = Set<String>()
        var total = 0
        var rollbackBytes = 0
        var changes: [QuasarMutationChange] = []
        for operation in plan.operations {
            let path: String
            let kind: QuasarMutationChange.Kind
            let byteCount: Int
            switch operation {
            case .write(let value, let content):
                path = value
                kind = .write
                byteCount = content.utf8.count
                guard byteCount <= limits.maximumFileBytes else { throw QuasarError.fileTooLarge }
                total += byteCount
                guard total <= limits.maximumTotalBytes else { throw QuasarError.budgetExceeded("total bytes") }
            case .remove(let value):
                path = value
                kind = .remove
                byteCount = 0
            }
            let destination = try guarder.resolve(path)
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true,
                      let existingBytes = values.fileSize,
                      existingBytes <= limits.maximumFileBytes
                else {
                    throw QuasarError.pathRejected("mutation targets must be regular files")
                }
                rollbackBytes += existingBytes
                guard rollbackBytes <= limits.maximumTotalBytes else {
                    throw QuasarError.budgetExceeded("rollback snapshot bytes")
                }
            }
            guard seen.insert(destination.path).inserted else {
                throw QuasarError.malformedPlan("duplicate operation destination: \(path)")
            }
            changes.append(.init(kind: kind, path: path, byteCount: byteCount))
        }

        let digest = try Self.digest(plan)
        let seconds = lifetime.components.seconds
        return QuasarMutationPreview(
            siteID: siteID,
            summary: plan.summary,
            planDigest: digest,
            changes: changes,
            totalWriteBytes: total,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(TimeInterval(seconds))
        )
    }

    public func apply(
        _ plan: QuasarMutationPlan,
        siteID rawSiteID: String,
        to siteRoot: URL,
        rollbackRoot: URL
    ) throws -> QuasarMutationReceipt {
        let siteID = try Self.checkedSiteID(rawSiteID)
        let planDigest = try Self.digest(plan)
        let completionKey = CompletionKey(siteID: siteID, idempotencyKey: plan.idempotencyKey)
        if let prior = completed[completionKey] {
            guard prior.planDigest == planDigest else { throw QuasarError.proposalChanged }
            return prior
        }
        _ = try validate(plan, siteID: siteID, siteRoot: siteRoot)
        let guarder = try QuasarPathGuard(root: siteRoot)
        let snapshot = rollbackRoot
            .appendingPathComponent(siteID, isDirectory: true)
            .appendingPathComponent(planDigest, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: snapshot.path) else {
            throw QuasarError.processFailed("rollback snapshot already exists; refusing an ambiguous replay")
        }
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        var originalFiles: [String: Data] = [:]
        var originallyAbsent = Set<String>()
        var rollbackEntries: [QuasarRollbackManifest.Entry] = []
        var rollbackBytes = 0
        do {
            for operation in plan.operations {
                let path: String
                switch operation {
                case .write(let value, _), .remove(let value): path = value
                }
                let destination = try guarder.resolve(path)
                if FileManager.default.fileExists(atPath: destination.path) {
                    let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true,
                          let expectedBytes = values.fileSize,
                          expectedBytes <= limits.maximumFileBytes
                    else { throw QuasarError.fileTooLarge }
                    let data = try Data(contentsOf: destination)
                    guard data.count == expectedBytes else { throw QuasarError.proposalChanged }
                    rollbackBytes += data.count
                    guard rollbackBytes <= limits.maximumTotalBytes else {
                        throw QuasarError.budgetExceeded("rollback snapshot bytes")
                    }
                    let backup = snapshot
                        .appendingPathComponent("files", isDirectory: true)
                        .appendingPathComponent(path)
                    try FileManager.default.createDirectory(
                        at: backup.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: backup, options: .atomic)
                    originalFiles[path] = data
                    rollbackEntries.append(.init(
                        path: path,
                        existedBefore: true,
                        byteCount: data.count,
                        sha256: Self.sha256(data)
                    ))
                } else {
                    originallyAbsent.insert(path)
                    rollbackEntries.append(.init(
                        path: path,
                        existedBefore: false,
                        byteCount: 0,
                        sha256: nil
                    ))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
        let rollbackManifest = QuasarRollbackManifest(
            siteID: siteID,
            planDigest: planDigest,
            entries: rollbackEntries
        )
        let rollbackEncoder = JSONEncoder()
        rollbackEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try rollbackEncoder.encode(rollbackManifest).write(to: snapshot.appendingPathComponent("receipt.json"), options: .atomic)
        var total = 0
        var changed: [String] = []
        do {
            for operation in plan.operations {
                let path: String
                let content: String?
                switch operation {
                case .write(let value, let body): path = value; content = body
                case .remove(let value): path = value; content = nil
                }
                let destination = try guarder.resolve(path)
                if let content {
                    let bytes = Data(content.utf8)
                    guard bytes.count <= limits.maximumFileBytes else { throw QuasarError.fileTooLarge }
                    total += bytes.count
                    guard total <= limits.maximumTotalBytes else { throw QuasarError.budgetExceeded("total bytes") }
                }
                if let content {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(content.utf8).write(to: destination, options: .atomic)
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                changed.append(path)
            }
        } catch {
            for path in changed.reversed() {
                let destination = try? guarder.resolve(path)
                if let destination {
                    if let original = originalFiles[path] {
                        try? FileManager.default.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try? original.write(to: destination, options: .atomic)
                    } else if originallyAbsent.contains(path),
                              FileManager.default.fileExists(atPath: destination.path) {
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
            }
            throw error
        }
        let receipt = QuasarMutationReceipt(
            siteID: siteID,
            idempotencyKey: plan.idempotencyKey,
            planDigest: planDigest,
            changedPaths: changed,
            rollbackDirectory: snapshot.path
        )
        completed[completionKey] = receipt
        return receipt
    }

    public func rollback(
        planDigest: String,
        siteID rawSiteID: String,
        siteRoot: URL,
        rollbackRoot: URL
    ) throws -> QuasarRollbackReceipt {
        let siteID = try Self.checkedSiteID(rawSiteID)
        guard planDigest.count == 64, planDigest.allSatisfy({ $0.isHexDigit }) else {
            throw QuasarError.invalidInput("plan digest must be 64 hexadecimal characters")
        }
        let snapshot = rollbackRoot
            .appendingPathComponent(siteID, isDirectory: true)
            .appendingPathComponent(planDigest, isDirectory: true)
        let rollbackGuard = try QuasarPathGuard(root: rollbackRoot)
        let manifestURL = try rollbackGuard.resolve(
            "\(siteID)/\(planDigest)/receipt.json",
            permitMissingLeaf: false
        )
        let manifest = try JSONDecoder().decode(QuasarRollbackManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.siteID == siteID,
              manifest.planDigest == planDigest,
              (1...limits.maximumOperations).contains(manifest.entries.count)
        else {
            throw QuasarError.proposalChanged
        }
        let guarder = try QuasarPathGuard(root: siteRoot)
        struct PreparedRollback {
            var path: String
            var destination: URL
            var currentData: Data?
            var restoredData: Data?
        }
        var prepared: [PreparedRollback] = []
        var seenDestinations = Set<String>()
        var seenBackups = Set<String>()
        var currentBytes = 0
        var restoredBytes = 0
        for entry in manifest.entries {
            let destination = try guarder.resolve(entry.path)
            guard seenDestinations.insert(destination.path).inserted else {
                throw QuasarError.proposalChanged
            }
            let currentData: Data?
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true,
                      let expectedBytes = values.fileSize,
                      expectedBytes <= limits.maximumFileBytes
                else { throw QuasarError.pathRejected("rollback target is not a bounded regular file") }
                let data = try Data(contentsOf: destination)
                guard data.count == expectedBytes else { throw QuasarError.proposalChanged }
                currentBytes += data.count
                guard currentBytes <= limits.maximumTotalBytes else {
                    throw QuasarError.budgetExceeded("pre-rollback snapshot bytes")
                }
                currentData = data
            } else {
                currentData = nil
            }

            let restoredData: Data?
            if entry.existedBefore {
                guard entry.byteCount >= 0,
                      entry.byteCount <= limits.maximumFileBytes,
                      let expectedDigest = entry.sha256
                else { throw QuasarError.processFailed("rollback snapshot metadata is incomplete") }
                let backup = try rollbackGuard.resolve(
                    "\(siteID)/\(planDigest)/files/\(entry.path)",
                    permitMissingLeaf: false
                )
                guard seenBackups.insert(backup.path).inserted else {
                    throw QuasarError.proposalChanged
                }
                let values = try backup.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true,
                      values.fileSize == entry.byteCount
                else { throw QuasarError.processFailed("rollback snapshot is incomplete") }
                let data = try Data(contentsOf: backup)
                guard data.count == entry.byteCount,
                      Self.sha256(data) == expectedDigest
                else { throw QuasarError.processFailed("rollback snapshot failed integrity verification") }
                restoredBytes += data.count
                guard restoredBytes <= limits.maximumTotalBytes else {
                    throw QuasarError.budgetExceeded("rollback snapshot bytes")
                }
                restoredData = data
            } else {
                guard entry.byteCount == 0, entry.sha256 == nil else {
                    throw QuasarError.processFailed("rollback snapshot metadata is inconsistent")
                }
                restoredData = nil
            }
            prepared.append(.init(
                path: entry.path,
                destination: destination,
                currentData: currentData,
                restoredData: restoredData
            ))
        }

        var restored: [String] = []
        do {
            for entry in prepared.reversed() {
                if let data = entry.restoredData {
                    try FileManager.default.createDirectory(
                        at: entry.destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: entry.destination, options: .atomic)
                } else if FileManager.default.fileExists(atPath: entry.destination.path) {
                    try FileManager.default.removeItem(at: entry.destination)
                }
                restored.append(entry.path)
            }
        } catch {
            for entry in prepared where restored.contains(entry.path) {
                if let data = entry.currentData {
                    try? FileManager.default.createDirectory(
                        at: entry.destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? data.write(to: entry.destination, options: .atomic)
                } else if FileManager.default.fileExists(atPath: entry.destination.path) {
                    try? FileManager.default.removeItem(at: entry.destination)
                }
            }
            throw error
        }
        return .init(planDigest: planDigest, restoredPaths: restored.sorted(), rolledBackAt: Date())
    }

    private static func digest(_ plan: QuasarMutationPlan) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let planData = try encoder.encode(plan)
        return SHA256.hash(data: planData).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func checkedSiteID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == raw,
              (1...128).contains(value.utf8.count),
              value.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
              })
        else { throw QuasarError.invalidInput("site id is invalid") }
        return value
    }
}
