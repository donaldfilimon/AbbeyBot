import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the server's list (pull) and write (push) endpoints, used by the CLI's
/// `/sync pull` and `/sync push`. Same contract the desktop uses: `?limit=` (max 500) +
/// optional `?since=<unix epoch>`, optional Bearer token. Push covers ingest + remember only
/// — reputation/interactions are re-derived by ingest, and equity/tombstones have no CLI
/// write surface.
public struct ServerSyncClient: Sendable {
    public enum ClientError: Error, LocalizedError, Sendable {
        case invalidURL(String)
        case httpStatus(Int)
        case decodeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let path): return "invalid sync URL for \(path)"
            case .httpStatus(let code): return "HTTP \(code)"
            case .decodeFailed(let path): return "failed to decode response for \(path)"
            }
        }
    }

    public struct IngestResult: Equatable, Sendable {
        public var ok: Bool
        public var discordMessageId: String
        public var duplicate: Bool

        public init(ok: Bool, discordMessageId: String, duplicate: Bool) {
            self.ok = ok
            self.discordMessageId = discordMessageId
            self.duplicate = duplicate
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

    /// `POST /api/ingest` with a preserved `discordMessageId`. Returns whether the server
    /// reported a duplicate skip (idempotent retry).
    @discardableResult
    public func pushIngest(
        discordMessageId: String,
        content: String,
        channelId: String,
        guildId: String,
        authorId: String
    ) async throws -> IngestResult {
        let body: [String: Any] = [
            "discordMessageId": discordMessageId,
            "content": content,
            "channelId": channelId,
            "guildId": guildId,
            "authorId": authorId
        ]
        let data = try await post(path: "/api/ingest", jsonObjectBody: body)
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(IngestResponseBody.self, from: data) else {
            throw ClientError.decodeFailed("/api/ingest")
        }
        return IngestResult(
            ok: decoded.ok,
            discordMessageId: decoded.discordMessageId,
            duplicate: decoded.duplicate
        )
    }

    /// `POST /api/state/remember`. Server-side append is already idempotent on identical fact text.
    public func pushRemember(userId: String, guildId: String, fact: String) async throws {
        let body: [String: Any] = [
            "userId": userId,
            "guildId": guildId,
            "fact": fact
        ]
        _ = try await post(path: "/api/state/remember", jsonObjectBody: body)
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

    private func post(path: String, jsonObjectBody: [String: Any]) async throws -> Data {
        guard let url = URL(string: baseURL + path) else {
            throw ClientError.invalidURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObjectBody)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.httpStatus(http.statusCode)
        }
        return data
    }
}

private struct IngestResponseBody: Decodable {
    var ok: Bool
    var discordMessageId: String
    var duplicate: Bool
}
