import AbbeyCore
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
        try await fetchUsersPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    public func fetchChannels(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Channel] {
        try await fetchChannelsPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    public func fetchMessages(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Message] {
        try await fetchMessagesPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    public func fetchReputation(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Reputation] {
        try await fetchReputationPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    public func fetchInteractions(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Interaction] {
        try await fetchInteractionsPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    public func fetchEquity(limit: Int = 500, since: Date? = nil) async throws -> [ServerSyncDTO.Equity] {
        try await fetchEquityPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    public func fetchUsersPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<ServerSyncDTO.User> {
        try await getPage(path: "/api/users", limit: limit, cursor: cursor)
    }

    public func fetchChannelsPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<ServerSyncDTO.Channel> {
        try await getPage(path: "/api/channels", limit: limit, cursor: cursor)
    }

    public func fetchMessagesPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<ServerSyncDTO.Message> {
        try await getPage(path: "/api/messages", limit: limit, cursor: cursor)
    }

    public func fetchReputationPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<ServerSyncDTO.Reputation> {
        try await getPage(path: "/api/reputation", limit: limit, cursor: cursor)
    }

    public func fetchInteractionsPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<ServerSyncDTO.Interaction> {
        try await getPage(path: "/api/interactions", limit: limit, cursor: cursor)
    }

    public func fetchEquityPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<ServerSyncDTO.Equity> {
        try await getPage(path: "/api/equity", limit: limit, cursor: cursor)
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

    private func getPage<T: Decodable & Sendable>(
        path: String,
        limit: Int,
        cursor: SyncPullCursor?
    ) async throws -> SyncPullPage<T> {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 500)))]
        if let cursor {
            query.append(URLQueryItem(
                name: SyncPullCursorWire.timeQuery,
                value: String(cursor.changedAt.timeIntervalSince1970)
            ))
            if let stableID = cursor.stableID {
                query.append(URLQueryItem(name: SyncPullCursorWire.idQuery, value: stableID))
            }
        }
        var request = try makeRequest(path: path, method: "GET", queryItems: query)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.httpStatus(0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let rows = try? decoder.decode([T].self, from: data) else {
            throw ClientError.decodeFailed(path)
        }
        return SyncPullPage(
            rows: rows,
            serverBoundary: Self.cursorBoundary(from: http),
            serverHighWatermark: Self.highWatermark(from: http)
        )
    }

    private static func cursorBoundary(from response: HTTPURLResponse) -> SyncPullCursor? {
        guard let rawTime = response.value(forHTTPHeaderField: SyncPullCursorWire.timeHeader),
              let epoch = Double(rawTime), epoch >= 0
        else { return nil }
        return SyncPullCursor(
            changedAt: Date(timeIntervalSince1970: epoch),
            stableID: response.value(forHTTPHeaderField: SyncPullCursorWire.idHeader)
        )
    }

    private static func highWatermark(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: SyncPullCursorWire.highWatermarkHeader),
              let epoch = Double(raw), epoch >= 0
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    private func post(path: String, jsonObjectBody: [String: Any]) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObjectBody)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.httpStatus(http.statusCode)
        }
        return data
    }

    /// Internal request boundary so tests can prove rejected transports never receive
    /// an Authorization header or a sync body. Delegates to the shared
    /// `SyncTransportPolicy.makeRequest` so the transport rules cannot drift per client.
    func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        do {
            return try SyncTransportPolicy.makeRequest(
                baseURL: baseURL,
                path: path,
                method: method,
                queryItems: queryItems,
                bearerToken: apiToken
            )
        } catch {
            throw ClientError.invalidURL(path)
        }
    }
}

private struct IngestResponseBody: Decodable {
    var ok: Bool
    var discordMessageId: String
    var duplicate: Bool
}
