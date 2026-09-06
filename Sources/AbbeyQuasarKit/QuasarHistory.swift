import Foundation

public struct QuasarRecoveryProblem: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case interruptedEffect
        case outcomePersistenceFailed
        case archiveIntegrityFailed
        case rollbackIntegrityFailed
    }

    public var code: Code
    public var message: String
    public var requiresOperatorReview: Bool

    public init(code: Code, message: String, requiresOperatorReview: Bool = true) {
        self.code = code
        self.message = message
        self.requiresOperatorReview = requiresOperatorReview
    }
}

public enum QuasarRecoveryResolution: String, Codable, Sendable {
    case confirmedApplied
    case confirmedNotApplied
}

public struct QuasarHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mutation
        case rollback
        case archive
        case restore
    }

    public enum Status: String, Codable, Sendable {
        case prepared
        case applying
        case succeeded
        case failed
        case uncertain
        case reconciled
    }

    public var schemaVersion: Int
    public var id: String
    public var siteID: String
    public var generationID: String?
    public var kind: Kind
    public var status: Status
    public var planDigest: String?
    public var dependencyFingerprint: QuasarDependencyFingerprint?
    public var paths: [String]
    public var startedAt: Date
    public var finishedAt: Date?
    public var problem: QuasarRecoveryProblem?
    public var recoveryResolution: QuasarRecoveryResolution?

    public init(
        schemaVersion: Int = 1,
        id: String = UUID().uuidString,
        siteID: String,
        generationID: String? = nil,
        kind: Kind,
        status: Status,
        planDigest: String? = nil,
        dependencyFingerprint: QuasarDependencyFingerprint? = nil,
        paths: [String] = [],
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        problem: QuasarRecoveryProblem? = nil,
        recoveryResolution: QuasarRecoveryResolution? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.siteID = siteID
        self.generationID = generationID
        self.kind = kind
        self.status = status
        self.planDigest = planDigest
        self.dependencyFingerprint = dependencyFingerprint
        self.paths = paths
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.problem = problem
        self.recoveryResolution = recoveryResolution
    }
}

/// Durable operation outcomes for a single-writer Quasar home. The registry's
/// file lock is the cross-process serialization boundary; QuasarService owns
/// all calls within the process.
public final class QuasarHistoryStore: @unchecked Sendable {
    private static let maximumRecordsPerSite = 2_048
    private let root: URL

    public init(home: URL) throws {
        root = home.standardizedFileURL.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try reconcileInterruptedEffects()
    }

    public func history(siteID: String) throws -> [QuasarHistoryRecord] {
        try Self.validateIdentifier(siteID)
        let url = recordURL(siteID: siteID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([QuasarHistoryRecord].self, from: Data(contentsOf: url))
        try Self.validate(records, siteID: siteID)
        return records
    }

    @discardableResult
    public func begin(
        siteID: String,
        generationID: String? = nil,
        kind: QuasarHistoryRecord.Kind,
        planDigest: String? = nil,
        dependencyFingerprint: QuasarDependencyFingerprint? = nil,
        paths: [String],
        at date: Date = Date()
    ) throws -> QuasarHistoryRecord {
        var records = try history(siteID: siteID)
        guard records.count < Self.maximumRecordsPerSite else {
            throw QuasarError.budgetExceeded("history entries")
        }
        let record = QuasarHistoryRecord(
            siteID: siteID,
            generationID: generationID,
            kind: kind,
            status: .applying,
            planDigest: planDigest,
            dependencyFingerprint: dependencyFingerprint,
            paths: paths,
            startedAt: date
        )
        records.append(record)
        try persist(records, siteID: siteID)
        return record
    }

    @discardableResult
    public func finish(
        _ operationID: String,
        siteID: String,
        status: QuasarHistoryRecord.Status,
        problem: QuasarRecoveryProblem? = nil,
        at date: Date = Date()
    ) throws -> QuasarHistoryRecord {
        guard status != .prepared, status != .applying else {
            throw QuasarError.invalidInput("operation completion status is invalid")
        }
        var records = try history(siteID: siteID)
        guard let index = records.firstIndex(where: { $0.id == operationID }) else {
            throw QuasarError.notFound
        }
        records[index].status = status
        records[index].finishedAt = date
        records[index].problem = problem
        try persist(records, siteID: siteID)
        return records[index]
    }

    public func currentMutation(siteID: String) throws -> QuasarHistoryRecord? {
        var applied: [QuasarHistoryRecord] = []
        for record in try history(siteID: siteID) where Self.isConfirmedApplied(record) {
            switch record.kind {
            case .mutation:
                applied.append(record)
            case .rollback:
                guard applied.last?.planDigest == record.planDigest else { return nil }
                applied.removeLast()
            case .archive, .restore:
                continue
            }
        }
        return applied.last
    }

    public func hasUnresolvedRecovery(siteID: String) throws -> Bool {
        try history(siteID: siteID).contains {
            $0.status == .applying || $0.status == .uncertain
        }
    }

    @discardableResult
    public func reconcile(
        siteID: String,
        recordID: String,
        resolution: QuasarRecoveryResolution,
        at date: Date = Date()
    ) throws -> QuasarHistoryRecord {
        var records = try history(siteID: siteID)
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].status == .uncertain
        else { throw QuasarError.notFound }
        records[index].status = .reconciled
        records[index].finishedAt = date
        records[index].recoveryResolution = resolution
        records[index].problem = .init(
            code: .interruptedEffect,
            message: resolution == .confirmedApplied
                ? "An operator inspected the durable evidence and confirmed that the interrupted effect was applied."
                : "An operator inspected the durable evidence and confirmed that the interrupted effect was not applied.",
            requiresOperatorReview: false
        )
        try persist(records, siteID: siteID)
        return records[index]
    }

    private static func isConfirmedApplied(_ record: QuasarHistoryRecord) -> Bool {
        record.status == .succeeded
            || (record.status == .reconciled && record.recoveryResolution == .confirmedApplied)
    }

    private func reconcileInterruptedEffects() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        for file in files where file.pathExtension == "json" {
            let siteID = file.deletingPathExtension().lastPathComponent
            guard (try? Self.validateIdentifier(siteID)) != nil else { continue }
            var records = try history(siteID: siteID)
            var changed = false
            for index in records.indices where records[index].status == .applying {
                records[index].status = .uncertain
                records[index].finishedAt = Date()
                records[index].problem = .init(
                    code: .interruptedEffect,
                    message: "The process stopped after this effect began and before its outcome was durably recorded. Inspect the site and its rollback/archive evidence before retrying.",
                    requiresOperatorReview: true
                )
                changed = true
            }
            if changed { try persist(records, siteID: siteID) }
        }
    }

    private func persist(_ records: [QuasarHistoryRecord], siteID: String) throws {
        try Self.validate(records, siteID: siteID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let destination = recordURL(siteID: siteID)
        let temporary = root.appendingPathComponent(".\(siteID).\(UUID().uuidString).tmp")
        try encoder.encode(records).write(to: temporary, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func recordURL(siteID: String) -> URL {
        root.appendingPathComponent("\(siteID).json")
    }

    private static func validate(_ records: [QuasarHistoryRecord], siteID: String) throws {
        guard records.count <= maximumRecordsPerSite,
              records.allSatisfy({
                  $0.schemaVersion == 1
                      && $0.siteID == siteID
                      && !$0.id.isEmpty
                      && $0.id.utf8.count <= 128
                      && $0.paths.count <= 32
                      && $0.paths.allSatisfy { !$0.isEmpty && $0.utf8.count <= 1_024 }
                      && ($0.planDigest == nil || Self.isDigest($0.planDigest!))
              })
        else { throw QuasarError.invalidInput("Quasar history is malformed") }
    }

    private static func validateIdentifier(_ value: String) throws {
        guard (1...128).contains(value.utf8.count),
              value.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
              })
        else { throw QuasarError.invalidInput("site id is invalid") }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
