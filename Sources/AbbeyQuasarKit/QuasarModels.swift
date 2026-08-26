import Foundation

public enum SiteStatus: String, Codable, Sendable { case idle, generating, error }
public enum PreviewState: String, Codable, Sendable { case stopped, starting, running, crashed }

public struct PromptEntry: Codable, Equatable, Sendable {
    public var prompt: String
    public var at: String
    public init(prompt: String, at: String) { self.prompt = prompt; self.at = at }
}

public struct Site: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var slug: String
    public var createdAt: String
    public var status: SiteStatus
    public var previewPort: Int?
    public var promptHistory: [PromptEntry]
    public var lastError: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        slug: String,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        status: SiteStatus = .idle,
        previewPort: Int? = nil,
        promptHistory: [PromptEntry] = [],
        lastError: String? = nil
    ) {
        self.id = id; self.name = name; self.slug = slug; self.createdAt = createdAt
        self.status = status; self.previewPort = previewPort
        self.promptHistory = promptHistory; self.lastError = lastError
    }
}

public struct GenerationEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, tool, plan, done, error }
    public enum ToolName: String, Codable, Sendable { case listFiles = "list_files", readFile = "read_file", writeFile = "write_file" }
    public var type: Kind
    public var text: String?
    public var name: ToolName?
    public var path: String?
    public var message: String?

    public init(type: Kind, text: String? = nil, name: ToolName? = nil, path: String? = nil, message: String? = nil) {
        self.type = type; self.text = text; self.name = name; self.path = path; self.message = message
    }
    public static func text(_ value: String) -> Self { .init(type: .text, text: value) }
    public static func tool(_ name: ToolName, path: String? = nil) -> Self { .init(type: .tool, name: name, path: path) }
    public static func plan(_ value: String) -> Self { .init(type: .plan, text: value) }
    public static var done: Self { .init(type: .done) }
    public static func error(_ value: String) -> Self { .init(type: .error, message: value) }
}

public struct EventPage: Codable, Equatable, Sendable {
    public var events: [GenerationEvent]
    public var next: Int
}

public struct PreviewStatus: Codable, Equatable, Sendable {
    public var state: PreviewState
    public var port: Int?
    public var url: String?
    public var logTail: [String]
    public init(state: PreviewState = .stopped, port: Int? = nil, url: String? = nil, logTail: [String] = []) {
        self.state = state; self.port = port; self.url = url; self.logTail = logTail
    }
}

public struct CreateSiteRequest: Codable, Sendable {
    public var name: String
    public var prompt: String
    public init(name: String, prompt: String) { self.name = name; self.prompt = prompt }
    public func validated() throws -> Self {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.count) else { throw QuasarError.invalidInput("name must contain 1...60 characters") }
        guard (1...4_000).contains(prompt.count) else { throw QuasarError.invalidInput("prompt must contain 1...4000 characters") }
        return .init(name: name, prompt: prompt)
    }
}

public enum QuasarError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String), notFound, jobRunning, pathRejected(String), fileTooLarge
    case registryLocked, providerUnqualified, malformedPlan(String), budgetExceeded(String)
    case authorizationDenied(String), proposalExpired, proposalChanged, processFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let value): return value
        case .notFound: return "Quasar site not found."
        case .jobRunning: return "A generation job is already running for this site."
        case .pathRejected(let value): return "Quasar path rejected: \(value)"
        case .fileTooLarge: return "Quasar file exceeds the 512 KiB limit."
        case .registryLocked: return "Quasar home is already owned by another writer."
        case .providerUnqualified: return "The selected Abbey inference provider is not qualified for structured planning."
        case .malformedPlan(let value): return "Quasar plan rejected: \(value)"
        case .budgetExceeded(let value): return "Quasar budget exceeded: \(value)"
        case .authorizationDenied(let value): return "Quasar authorization denied: \(value)"
        case .proposalExpired: return "Quasar proposal expired."
        case .proposalChanged: return "Quasar proposal facts changed and must be proposed again."
        case .processFailed(let value): return "Quasar process failed: \(value)"
        }
    }
}

public enum QuasarSlug {
    public static func make(_ name: String) -> String {
        let lowered = name.lowercased()
        let pieces = lowered.split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
        let slug = pieces.joined(separator: "-")
        return slug.isEmpty ? "site" : slug
    }
}
