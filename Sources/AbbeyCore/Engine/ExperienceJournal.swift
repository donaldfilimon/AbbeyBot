import Foundation

/// Append-only durable DQN experience journal (Phase 2). Default `~/.abbey/dqn-experience.jsonl`.
public enum ExperienceJournalStore: Sendable {
    public static func defaultURL() throws -> URL {
        let dir = try AbbeyDataDirectory.ensure()
        return dir.appendingPathComponent("dqn-experience.jsonl", isDirectory: false)
    }
}

/// One JSONL line — mirrors `Experience` for on-disk persistence.
public struct ExperienceJournalRecord: Codable, Sendable, Equatable {
    public var state: [Float]
    public var action: Int
    public var reward: Float
    public var nextState: [Float]
    public var done: Bool
    public var recordedAt: Date

    public init(from experience: Experience, recordedAt: Date = Date()) {
        self.state = experience.state
        self.action = experience.action
        self.reward = experience.reward
        self.nextState = experience.nextState
        self.done = experience.done
        self.recordedAt = recordedAt
    }

    public func asExperience() -> Experience {
        Experience(state: state, action: action, reward: reward, nextState: nextState, done: done)
    }
}

public enum ExperienceJournalError: Error, LocalizedError, Sendable {
    case io(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .io(let detail): return "Experience journal I/O: \(detail)"
        case .corrupt(let detail): return "Experience journal corrupt: \(detail)"
        }
    }
}

/// Append-only JSONL writer/reader. Not an actor — owned by `DQNAgent`.
public struct ExperienceJournal: Sendable {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func append(_ experience: Experience) throws {
        let record = ExperienceJournalRecord(from: experience)
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw ExperienceJournalError.corrupt(error.localizedDescription)
        }
        var line = data
        line.append(contentsOf: [0x0A]) // newline
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch let error as ExperienceJournalError {
            throw error
        } catch {
            throw ExperienceJournalError.io(error.localizedDescription)
        }
    }

    /// Load up to `limit` most recent records (scan from end of file when large).
    public func loadRecent(limit: Int = 10_000) throws -> [Experience] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExperienceJournalError.io(error.localizedDescription)
        }
        guard !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        let slice = lines.suffix(max(limit, 0))
        var out: [Experience] = []
        out.reserveCapacity(slice.count)
        for line in slice {
            do {
                let record = try decoder.decode(ExperienceJournalRecord.self, from: Data(line.utf8))
                out.append(record.asExperience())
            } catch {
                throw ExperienceJournalError.corrupt(error.localizedDescription)
            }
        }
        return out
    }
}
