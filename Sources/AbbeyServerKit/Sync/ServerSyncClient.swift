import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP puller for the server's list endpoints, used by the CLI's `/sync pull`.
/// Same contract the desktop uses: `?limit=` (max 500) + optional `?since=<unix epoch>`,
/// optional Bearer token. Read-only — pushing stays a desktop concern (durable outbox there).
public struct ServerSyncClient: Sendable {
    public enum ClientError: Error, LocalizedError, Sendable {
        case invalidURL(String)
        case httpStatus(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let path): return "invalid sync URL for \(path)"
            case .httpStatus(let code): return "HTTP \(code)"
            }
        }
    }

    public let baseURL: String
    public let apiToken: String?
    private let session: URLSession

    public init(baseURL: String, apiToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiToken = (apiToken?.isEmpty == true) ? nil : apiToken
        self.session = session
    }

    /// Builds a client from `ABBEY_SYNC_SERVER_URL` / `ABBEY_SYNC_API_TOKEN` (the same env
    /// vars the desktop's Settings mirror). Nil when the URL is unset — sync unconfigured.
    public static func fromEnvironment(_ environment: [String: String]) -> ServerSyncClient? {
        let url = (environment["ABBEY_SYNC_SERVER_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let token = (environment["ABBEY_SYNC_API_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ServerSyncClient(baseURL: url, apiToken: token.isEmpty ? nil : token)
    }

    public func fetchUsers(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.User] {
        try await get(path: "/api/users", limit: limit, since: since)
    }

    public func fetchChannels(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Channel] {
        try await get(path: "/api/channels", limit: limit, since: since)
    }

    public func fetchMessages(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Message] {
        try await get(path: "/api/messages", limit: limit, since: since)
    }

    public func fetchReputation(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Reputation] {
        try await get(path: "/api/reputation", limit: limit, since: since)
    }

    public func fetchInteractions(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Interaction] {
        try await get(path: "/api/interactions", limit: limit, since: since)
    }

    public func fetchEquity(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Equity] {
        try await get(path: "/api/equity", limit: limit, since: since)
    }

    private func get<T: Decodable>(path: String, limit: Int, since: Date?) async throws -> T {
        guard var components = URLComponents(string: baseURL + path) else {
            throw ClientError.invalidURL(path)
        }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let since {
            query.append(URLQueryItem(name: "since", value: String(since.timeIntervalSince1970)))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw ClientError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
