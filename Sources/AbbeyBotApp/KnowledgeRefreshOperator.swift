import AbbeyCore
import Foundation

struct KnowledgeSnapshotOperatorStatus: Sendable {
    var aggregateDigest: String
    var entryCount: Int
    var formatVersion: Int
    var snapshotPath: String
}

struct KnowledgeRefreshCandidate: Sendable {
    var digest: String
    var report: KnowledgeRefreshReport
    var candidatePath: String
}

enum KnowledgeRefreshOperatorError: LocalizedError {
    case repositoryRootUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .repositoryRootUnavailable:
            return "Set ABBEY_REPOSITORY_ROOT to the AbbeyBot checkout before staging an ecosystem refresh."
        case .commandFailed(let value):
            return "Knowledge refresh command failed: \(value)"
        }
    }
}

enum KnowledgeRefreshOperator {
    static func bundledStatus() throws -> KnowledgeSnapshotOperatorStatus {
        let root = try KnowledgeSnapshotLoader.bundledSnapshotURL()
        let manifest = try JSONDecoder().decode(
            KnowledgeManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        )
        return .init(
            aggregateDigest: manifest.aggregateDigest,
            entryCount: manifest.entries.count,
            formatVersion: manifest.formatVersion,
            snapshotPath: root.path
        )
    }

    static func repositoryRoot(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        var candidates: [URL] = []
        if let configured = environment["ABBEY_REPOSITORY_ROOT"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        var cursor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            candidates.append(cursor)
            cursor.deleteLastPathComponent()
        }
        guard let root = candidates.map(\.standardizedFileURL).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("Scripts/refresh-knowledge-snapshot.swift").path)
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path)
        }) else { throw KnowledgeRefreshOperatorError.repositoryRootUnavailable }
        return root
    }

    static func stage(root: URL) throws -> KnowledgeRefreshCandidate {
        try run(root: root, arguments: [])
        let candidate = root.appendingPathComponent(".build/knowledge-snapshot-candidate", isDirectory: true)
        let manifest = try JSONDecoder().decode(KnowledgeManifest.self, from: Data(contentsOf: candidate.appendingPathComponent("manifest.json")))
        let report = try JSONDecoder().decode(KnowledgeRefreshReport.self, from: Data(contentsOf: candidate.appendingPathComponent("refresh-report.json")))
        return .init(digest: manifest.aggregateDigest, report: report, candidatePath: candidate.path)
    }

    static func apply(root: URL, reviewedDigest: String) throws -> [KnowledgeDocument] {
        try run(root: root, arguments: ["--apply", "--reviewed-digest", reviewedDigest])
        return try KnowledgeSnapshotLoader.loadVerified(
            snapshotRoot: root.appendingPathComponent("Sources/AbbeyCore/Resources/KnowledgeSnapshot", isDirectory: true)
        )
    }

    private static func run(root: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = root.appendingPathComponent("Scripts/refresh-knowledge-snapshot.swift")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Read concurrently with process execution so a large candidate/report
        // cannot fill the pipe and deadlock before `waitUntilExit`.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KnowledgeRefreshOperatorError.commandFailed(String(decoding: data.suffix(4_096), as: UTF8.self))
        }
    }
}
