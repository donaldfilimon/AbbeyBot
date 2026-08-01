import Foundation

/// One vector row in the local WDBX-style store (claim-honest: on-disk segments under
/// `~/.abbey/wdbx/`, not the Zig abi WDBX engine).
public struct WDBXRecord: Codable, Sendable, Equatable {
    public var id: String
    public var vector: [Float]
    public var payload: [String: String]
    public var createdAt: Date

    public init(id: String, vector: [Float], payload: [String: String], createdAt: Date = .now) {
        self.id = id
        self.vector = vector
        self.payload = payload
        self.createdAt = createdAt
    }
}

public struct WDBXManifest: Codable, Sendable, Equatable {
    public var version: Int
    public var dimension: Int
    public var segmentCount: Int
    public var recordCount: Int
    public var updatedAt: Date

    public init(version: Int = 2, dimension: Int, segmentCount: Int = 0, recordCount: Int = 0, updatedAt: Date = .now) {
        self.version = version
        self.dimension = dimension
        self.segmentCount = segmentCount
        self.recordCount = recordCount
        self.updatedAt = updatedAt
    }
}

public struct WDBXSearchHit: Sendable, Equatable {
    public var record: WDBXRecord
    public var score: Float
    public init(record: WDBXRecord, score: Float) {
        self.record = record
        self.score = score
    }
}

public enum WDBXStoreError: Error, LocalizedError, Sendable {
    case io(String)
    case corrupt(String)
    case dimensionMismatch(expected: Int, found: Int)

    public var errorDescription: String? {
        switch self {
        case .io(let d): return "WDBX I/O: \(d)"
        case .corrupt(let d): return "WDBX corrupt: \(d)"
        case .dimensionMismatch(let e, let f): return "WDBX dimension mismatch (expected \(e), found \(f))"
        }
    }
}

/// Append-only segmented JSONL vector store with cosine search.
/// Layout: `root/manifest.json`, `root/segments/seg-NNNN.jsonl`
public final class WDBXStore: @unchecked Sendable {
    /// Retrieval never returns weak or negatively correlated rows, even if a caller
    /// accidentally requests a lower threshold.
    public static let safeMinimumSimilarity: Float = 0.35
    private static let currentManifestVersion = 2
    private static let sensitivePayloadKeys: Set<String> = ["contentPreview"]

    public let root: URL
    public let dimension: Int
    private let maxRecordsPerSegment: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var manifest: WDBXManifest
    private var cache: [WDBXRecord] = []
    private var appendedRecordCount = 0

    public static func defaultRoot() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".abbey/wdbx", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("segments", isDirectory: true),
            withIntermediateDirectories: true
        )
        return dir
    }

    public convenience init(dimension: Int = SentimentAnalyzer.stateDimension) throws {
        try self.init(root: try Self.defaultRoot(), dimension: dimension)
    }

    public init(root: URL, dimension: Int = SentimentAnalyzer.stateDimension, maxRecordsPerSegment: Int = 2_000) throws {
        self.root = root
        self.dimension = dimension
        self.maxRecordsPerSegment = max(100, maxRecordsPerSegment)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("segments", isDirectory: true),
            withIntermediateDirectories: true
        )

        let manifestURL = root.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            self.manifest = try decoder.decode(WDBXManifest.self, from: data)
            if self.manifest.dimension != dimension {
                throw WDBXStoreError.dimensionMismatch(expected: dimension, found: self.manifest.dimension)
            }
        } else {
            self.manifest = WDBXManifest(dimension: dimension)
            try Self.writeManifest(self.manifest, to: manifestURL, encoder: encoder)
        }
        let loaded = try Self.loadAllRecords(root: root, decoder: decoder)
        let sanitizedRecords = loaded.records.map(Self.sanitizedRecord)
        let scrubbedSensitivePayload = sanitizedRecords != loaded.records
        self.cache = sanitizedRecords
        self.appendedRecordCount = scrubbedSensitivePayload
            ? sanitizedRecords.count
            : loaded.appendedRecordCount

        // Segments are an append-only log. Rebuild logical counts from that log so
        // repeated upserts do not reappear as duplicate live rows after a restart.
        // Version 2 also physically compacts legacy raw `contentPreview` fields out of
        // every segment. Retrieval uses authoritative memory stores instead.
        let repairedSegmentCount = scrubbedSensitivePayload
            ? try Self.rewriteSegments(
                records: sanitizedRecords,
                root: root,
                maxRecordsPerSegment: self.maxRecordsPerSegment,
                encoder: encoder
            )
            : loaded.segmentCount
        if manifest.version != Self.currentManifestVersion
            || manifest.recordCount != cache.count
            || manifest.segmentCount != repairedSegmentCount
        {
            manifest.version = Self.currentManifestVersion
            manifest.recordCount = cache.count
            manifest.segmentCount = repairedSegmentCount
            manifest.updatedAt = .now
            try Self.writeManifest(manifest, to: manifestURL, encoder: encoder)
        }
    }

    public var recordCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache.count
    }

    public var manifestSnapshot: WDBXManifest {
        lock.lock(); defer { lock.unlock() }
        return manifest
    }

    public func upsert(_ record: WDBXRecord) throws {
        let record = Self.sanitizedRecord(record)
        guard record.vector.count == dimension else {
            throw WDBXStoreError.dimensionMismatch(expected: dimension, found: record.vector.count)
        }
        lock.lock()
        defer { lock.unlock() }

        if let idx = cache.firstIndex(where: { $0.id == record.id }) {
            cache.remove(at: idx)
        }
        cache.append(record)
        manifest.recordCount = cache.count

        let segmentIndex = appendedRecordCount / maxRecordsPerSegment
        appendedRecordCount += 1
        manifest.segmentCount = max(manifest.segmentCount, segmentIndex + 1)
        manifest.updatedAt = .now

        let segURL = segmentURL(index: segmentIndex)
        var line = try encoder.encode(record)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: segURL.path) {
            let handle = try FileHandle(forWritingTo: segURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: segURL, options: .atomic)
        }
        try Self.writeManifest(manifest, to: root.appendingPathComponent("manifest.json"), encoder: encoder)
    }

    /// Guild-scoped cosine similarity search over the in-memory cache.
    ///
    /// `guildId` is intentionally mandatory. Optional channel/user filters can only
    /// narrow that scope; records without a matching guild are never retrievable.
    public func search(
        query: [Float],
        guildId: String,
        channelId: String? = nil,
        userId: String? = nil,
        minimumSimilarity: Float = WDBXStore.safeMinimumSimilarity,
        limit: Int = 8
    ) -> [WDBXSearchHit] {
        guard query.count == dimension, limit > 0, !guildId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        lock.lock()
        let rows = cache.filter { row in
            guard row.payload["guildId"] == guildId else { return false }
            if let channelId, row.payload["channelId"] != channelId { return false }
            if let userId {
                let storedUserId = row.payload["userId"] ?? row.payload["authorId"]
                if storedUserId != userId { return false }
            }
            return true
        }
        lock.unlock()
        let qNorm = Self.norm(query)
        guard qNorm > 1e-8 else { return [] }
        let threshold: Float
        if minimumSimilarity.isFinite {
            threshold = min(1, max(Self.safeMinimumSimilarity, minimumSimilarity))
        } else {
            threshold = Self.safeMinimumSimilarity
        }
        var hits: [WDBXSearchHit] = []
        hits.reserveCapacity(min(limit, rows.count))
        for row in rows {
            guard row.vector.count == dimension else { continue }
            let rowNorm = Self.norm(row.vector)
            guard rowNorm > 1e-8 else { continue }
            let score = Self.dot(query, row.vector) / (qNorm * rowNorm)
            guard score.isFinite, score >= threshold else { continue }
            hits.append(WDBXSearchHit(record: row, score: score))
        }
        hits.sort { $0.score > $1.score }
        if hits.count > limit { hits = Array(hits.prefix(limit)) }
        return hits
    }

    public func recent(limit: Int = 50) -> [WDBXRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(cache.suffix(limit).reversed())
    }

    private func segmentURL(index: Int) -> URL {
        root.appendingPathComponent("segments", isDirectory: true)
            .appendingPathComponent(String(format: "seg-%04d.jsonl", index))
    }

    private static func writeManifest(_ manifest: WDBXManifest, to url: URL, encoder: JSONEncoder) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private struct LoadedRecords {
        var records: [WDBXRecord]
        var appendedRecordCount: Int
        var segmentCount: Int
    }

    private static func loadAllRecords(root: URL, decoder: JSONDecoder) throws -> LoadedRecords {
        let segDir = root.appendingPathComponent("segments", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: segDir, includingPropertiesForKeys: nil)) ?? []
        let sorted = files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var latestByID: [String: (order: Int, record: WDBXRecord)] = [:]
        var appendedRecordCount = 0
        for file in sorted {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                guard let data = line.data(using: .utf8) else { continue }
                if let rec = try? decoder.decode(WDBXRecord.self, from: data) {
                    latestByID[rec.id] = (appendedRecordCount, rec)
                    appendedRecordCount += 1
                }
            }
        }
        let records = latestByID.values
            .sorted { $0.order < $1.order }
            .map(\.record)
        return LoadedRecords(
            records: records,
            appendedRecordCount: appendedRecordCount,
            segmentCount: sorted.count
        )
    }

    private static func sanitizedRecord(_ record: WDBXRecord) -> WDBXRecord {
        var sanitized = record
        for key in sensitivePayloadKeys {
            sanitized.payload.removeValue(forKey: key)
        }
        return sanitized
    }

    /// Rewrite the live logical rows into compacted segments. Atomic replacement happens
    /// per file; if a process stops midway, the next initialization repeats the scrub over
    /// every remaining segment before the store becomes available.
    private static func rewriteSegments(
        records: [WDBXRecord],
        root: URL,
        maxRecordsPerSegment: Int,
        encoder: JSONEncoder
    ) throws -> Int {
        let segmentDirectory = root.appendingPathComponent("segments", isDirectory: true)
        let existing = ((try? FileManager.default.contentsOfDirectory(
            at: segmentDirectory,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "jsonl" }

        let segmentCount = records.isEmpty
            ? 0
            : Int(ceil(Double(records.count) / Double(maxRecordsPerSegment)))
        for segmentIndex in 0..<segmentCount {
            let start = segmentIndex * maxRecordsPerSegment
            let end = min(start + maxRecordsPerSegment, records.count)
            var data = Data()
            for record in records[start..<end] {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            let url = segmentDirectory.appendingPathComponent(
                String(format: "seg-%04d.jsonl", segmentIndex)
            )
            try data.write(to: url, options: .atomic)
        }

        for url in existing {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let rawIndex = stem.split(separator: "-").last,
                  let index = Int(rawIndex), index >= segmentCount
            else { continue }
            try FileManager.default.removeItem(at: url)
        }
        return segmentCount
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        NeuralMath.dot(a, b)
    }

    private static func norm(_ v: [Float]) -> Float {
        sqrt(max(NeuralMath.dot(v, v), 0))
    }
}
