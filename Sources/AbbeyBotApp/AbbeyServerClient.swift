import Foundation
import AbbeyCore

/// Best-effort HTTP client that mirrors desktop SwiftData writes to the running
/// AbbeyServer, and pulls list endpoints for sync MVP.
///
/// POST methods are deliberately non-throwing to callers: every method swallows
/// its own errors and logs them, and every call is expected to be fired from a
/// detached/unstructured `Task` at the call site so it never blocks the caller
/// or the main actor. Sync is "off" (a silent no-op) whenever
/// `AppConfig.shared.syncServerURL` is empty.
///
/// GET fetch helpers throw so pull can surface failures into `SyncStatus`.
struct AbbeyServerClient: Sendable {
    static let shared = AbbeyServerClient()

    private let session: URLSession
    private let outbox: PendingPushQueue?

    init(session: URLSession = .shared) {
        self.session = session
        self.outbox = try? PendingPushQueue(url: PendingPushQueue.defaultURL())
    }

    /// Resend everything in the durable outbox (pushes that failed to reach the server
    /// last time). Best-effort like every other push here — never throws. Call this
    /// opportunistically whenever the app has reason to believe connectivity may have
    /// returned (e.g. before/after a sync pull).
    func flushPendingPushes() async -> Int {
        guard let outbox else { return 0 }
        return (try? await outbox.drain { path, bodyJSON in
            await self.postRaw(path: path, bodyJSON: bodyJSON)
        }) ?? 0
    }

    // MARK: - Public API (push)

    func ingest(
        content: String,
        channelId: String,
        guildId: String,
        authorId: String,
        discordMessageId: String?
    ) async {
        var body: [String: String] = [
            "content": content,
            "channelId": channelId,
            "guildId": guildId,
            "authorId": authorId
        ]
        if let discordMessageId {
            body["discordMessageId"] = discordMessageId
        }
        await post(path: "/api/ingest", body: body)
    }

    func remember(guildId: String, userId: String, fact: String) async {
        let body: [String: String] = [
            "guildId": guildId,
            "userId": userId,
            "fact": fact
        ]
        await post(path: "/api/state/remember", body: body)
    }

    func forget(guildId: String, userId: String, index: Int) async {
        let body: [String: JSONValue] = [
            "guildId": .string(guildId),
            "userId": .string(userId),
            "index": .int(index)
        ]
        await post(path: "/api/state/forget", body: body)
    }

    // MARK: - Public API (pull)

    func fetchUsers(limit: Int = 500) async throws -> [SyncDTO.User] {
        try await get(path: "/api/users", limit: limit)
    }

    func fetchChannels(limit: Int = 500) async throws -> [SyncDTO.Channel] {
        try await get(path: "/api/channels", limit: limit)
    }

    func fetchMessages(limit: Int = 500) async throws -> [SyncDTO.Message] {
        try await get(path: "/api/messages", limit: limit)
    }

    func fetchReputation(limit: Int = 500) async throws -> [SyncDTO.Reputation] {
        try await get(path: "/api/reputation", limit: limit)
    }

    func fetchInteractions(limit: Int = 500) async throws -> [SyncDTO.Interaction] {
        try await get(path: "/api/interactions", limit: limit)
    }

    func fetchEquity(limit: Int = 500) async throws -> [SyncDTO.Equity] {
        try await get(path: "/api/equity", limit: limit)
    }

    // MARK: - Internals

    /// Minimal JSON value so we can mix strings and an int in one request body
    /// without pulling in `Encodable` boilerplate for a two-shape payload.
    private enum JSONValue {
        case string(String)
        case int(Int)

        var jsonObject: Any {
            switch self {
            case .string(let value): return value
            case .int(let value): return value
            }
        }
    }

    enum SyncClientError: Error, LocalizedError, Sendable {
        case notConfigured
        case invalidURL(String)
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "syncServerURL is empty"
            case .invalidURL(let path):
                return "invalid syncServerURL for \(path)"
            case .httpStatus(let code):
                return "HTTP \(code)"
            }
        }
    }

    private func post(path: String, body: [String: String]) async {
        let objectBody = body.mapValues { $0 as Any }
        await post(path: path, jsonObjectBody: objectBody)
    }

    private func post(path: String, body: [String: JSONValue]) async {
        let objectBody = body.mapValues { $0.jsonObject }
        await post(path: path, jsonObjectBody: objectBody)
    }

    private func post(path: String, jsonObjectBody: [String: Any]) async {
        let bodyJSON: Data
        do {
            bodyJSON = try JSONSerialization.data(withJSONObject: jsonObjectBody)
        } catch {
            print("[sync] failed to encode body for \(path): \(error)")
            await recordFailure(path: path, message: "encode failed")
            return
        }

        let succeeded = await postRaw(path: path, bodyJSON: bodyJSON)
        if !succeeded {
            // Encode failures above are permanent and never enqueued; network/HTTP
            // failures here are — a later flushPendingPushes() (or app relaunch) retries them.
            try? outbox?.enqueue(path: path, jsonObjectBody: jsonObjectBody)
        }
    }

    /// Send pre-encoded JSON to `path`, recording success/failure on `SyncStatus`.
    /// Returns whether it reached the server with a 2xx — never throws.
    private func postRaw(path: String, bodyJSON: Data) async -> Bool {
        do {
            var request = try makeRequest(path: path, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyJSON

            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[sync] \(path) returned status \(http.statusCode)")
                await recordFailure(path: path, message: "HTTP \(http.statusCode)")
                return false
            }
            await recordSuccess(path: path)
            return true
        } catch SyncClientError.notConfigured {
            // Sync is unconfigured — silently no-op, not a failure worth retrying.
            return true
        } catch {
            print("[sync] \(path) failed: \(error)")
            await recordFailure(path: path, message: OperatorFacingError.message(error))
            return false
        }
    }

    private func get<T: Decodable>(path: String, limit: Int) async throws -> T {
        let clamped = min(max(limit, 1), 500)
        var request = try makeRequest(
            path: path,
            method: "GET",
            queryItems: [URLQueryItem(name: "limit", value: String(clamped))]
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SyncClientError.httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    /// Shared base URL + optional Bearer token for POST and GET.
    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        let rawBase = AppConfig.shared.syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBase.isEmpty else {
            throw SyncClientError.notConfigured
        }
        let base = rawBase.hasSuffix("/") ? String(rawBase.dropLast()) : rawBase
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: base + suffix) else {
            throw SyncClientError.invalidURL(path)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw SyncClientError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        let token = AppConfig.shared.syncAPIToken
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func recordSuccess(path: String) async {
        await MainActor.run {
            SyncStatus.shared.recordSuccess(path: path)
        }
    }

    private func recordFailure(path: String, message: String) async {
        await MainActor.run {
            SyncStatus.shared.recordFailure(path: path, message: message)
        }
    }
}
