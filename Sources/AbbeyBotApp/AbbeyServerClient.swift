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
    private let syncServerURL: @Sendable () -> String
    private let syncAPIToken: @Sendable () -> String
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        session: URLSession = .shared,
        syncServerURL: @escaping @Sendable () -> String = { AppConfig.shared.syncServerURL },
        syncAPIToken: @escaping @Sendable () -> String = { AppConfig.shared.syncAPIToken },
        outbox: PendingPushQueue? = try? PendingPushQueue(url: PendingPushQueue.defaultURL()),
        transport: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.session = session
        self.outbox = outbox
        self.syncServerURL = syncServerURL
        self.syncAPIToken = syncAPIToken
        self.transport = transport ?? { try await session.data(for: $0) }
    }

    /// Resend everything in the durable outbox (pushes that failed to reach the server
    /// last time). Best-effort like every other push here — never throws. Call this
    /// opportunistically whenever the app has reason to believe connectivity may have
    /// returned (e.g. before/after a sync pull).
    func flushPendingPushes() async -> Int {
        guard let outbox, let destination = try? destinationSnapshot() else { return 0 }
        return (try? await outbox.drain(endpoint: destination.endpoint) { path, bodyJSON in
            await self.postRaw(path: path, bodyJSON: bodyJSON, destination: destination)
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

    /// Soft-delete a user-memory row on the server so the next incremental pull can tombstone it locally.
    func tombstoneUser(guildId: String, userId: String) async {
        let body: [String: String] = [
            "guildId": guildId,
            "userId": userId
        ]
        await post(path: "/api/state/tombstone/user", body: body)
    }

    /// Soft-delete a channel-context row on the server so the next incremental pull can tombstone it locally.
    func tombstoneChannel(guildId: String, channelId: String) async {
        let body: [String: String] = [
            "guildId": guildId,
            "channelId": channelId
        ]
        await post(path: "/api/state/tombstone/channel", body: body)
    }

    func tombstoneMessage(discordMessageId: String) async {
        await post(path: "/api/state/tombstone/message", body: ["discordMessageId": discordMessageId])
    }

    func tombstoneReputation(id: UUID) async {
        await post(path: "/api/state/tombstone/reputation", body: ["id": id.uuidString])
    }

    func tombstoneInteraction(id: UUID) async {
        await post(path: "/api/state/tombstone/interaction", body: ["id": id.uuidString])
    }

    func tombstoneEquity(symbol: String) async {
        await post(path: "/api/state/tombstone/equity", body: ["symbol": symbol])
    }

    /// Reports the desktop's current sync outcome so the operator dashboard's Sync tab
    /// can show it. Best-effort like every other push — benefits from the same durable
    /// outbox retry as ingest/remember/forget.
    func reportSyncStatus(
        lastPullAt: Date?,
        lastPullError: String?,
        lastPushAt: Date?,
        lastPushError: String?,
        pendingPushCount: Int
    ) async {
        // Matches Vapor's default Content date strategy (ISO 8601), so the server decoding
        // SyncStatusReportDTO's Date? fields with the default JSONDecoder round-trips cleanly.
        let iso8601 = ISO8601DateFormatter()
        var body: [String: JSONValue] = ["pendingPushCount": .int(pendingPushCount)]
        if let lastPullAt { body["lastPullAt"] = .string(iso8601.string(from: lastPullAt)) }
        if let lastPullError { body["lastPullError"] = .string(lastPullError) }
        if let lastPushAt { body["lastPushAt"] = .string(iso8601.string(from: lastPushAt)) }
        if let lastPushError { body["lastPushError"] = .string(lastPushError) }
        await post(path: "/api/state/sync-status", body: body)
    }

    /// Number of pushes currently queued for retry in the durable outbox.
    func pendingPushCount() -> Int {
        guard let outbox else { return 0 }
        return (try? outbox.pendingCount()) ?? 0
    }

    // MARK: - Public API (pull)

    func fetchUsers(limit: Int = 500, since: Date? = nil) async throws -> [SyncDTO.User] {
        try await fetchUsersPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    func fetchChannels(limit: Int = 500, since: Date? = nil) async throws -> [SyncDTO.Channel] {
        try await fetchChannelsPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    func fetchMessages(limit: Int = 500, since: Date? = nil) async throws -> [SyncDTO.Message] {
        try await fetchMessagesPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    func fetchReputation(limit: Int = 500, since: Date? = nil) async throws -> [SyncDTO.Reputation] {
        try await fetchReputationPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    func fetchInteractions(limit: Int = 500, since: Date? = nil) async throws -> [SyncDTO.Interaction] {
        try await fetchInteractionsPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    func fetchEquity(limit: Int = 500, since: Date? = nil) async throws -> [SyncDTO.Equity] {
        try await fetchEquityPage(limit: limit, cursor: since.map { SyncPullCursor(changedAt: $0) }).rows
    }

    func fetchUsersPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<SyncDTO.User> {
        try await getPage(path: "/api/users", limit: limit, cursor: cursor)
    }

    func fetchChannelsPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<SyncDTO.Channel> {
        try await getPage(path: "/api/channels", limit: limit, cursor: cursor)
    }

    func fetchMessagesPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<SyncDTO.Message> {
        try await getPage(path: "/api/messages", limit: limit, cursor: cursor)
    }

    func fetchReputationPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<SyncDTO.Reputation> {
        try await getPage(path: "/api/reputation", limit: limit, cursor: cursor)
    }

    func fetchInteractionsPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<SyncDTO.Interaction> {
        try await getPage(path: "/api/interactions", limit: limit, cursor: cursor)
    }

    func fetchEquityPage(limit: Int = 500, cursor: SyncPullCursor?) async throws -> SyncPullPage<SyncDTO.Equity> {
        try await getPage(path: "/api/equity", limit: limit, cursor: cursor)
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
        let destination: Destination
        do {
            destination = try destinationSnapshot()
        } catch SyncClientError.notConfigured {
            return
        } catch {
            await recordFailure(path: path, message: OperatorFacingError.message(error))
            return
        }
        let bodyJSON: Data
        do {
            bodyJSON = try JSONSerialization.data(withJSONObject: jsonObjectBody)
        } catch {
            print("[sync] failed to encode body for \(path): \(error)")
            await recordFailure(path: path, message: "encode failed")
            return
        }

        let succeeded = await postRaw(path: path, bodyJSON: bodyJSON, destination: destination)
        if !succeeded {
            // Encode failures above are permanent and never enqueued; network/HTTP
            // failures here are — a later flushPendingPushes() (or app relaunch) retries them.
            try? outbox?.enqueue(path: path, jsonObjectBody: jsonObjectBody, endpoint: destination.endpoint)
        }
    }

    /// Send pre-encoded JSON to `path`, recording success/failure on `SyncStatus`.
    /// Returns whether it reached the server with a 2xx — never throws.
    private func postRaw(path: String, bodyJSON: Data, destination: Destination) async -> Bool {
        do {
            var request = try SyncTransportPolicy.makeRequest(
                baseURL: destination.endpoint, path: path, method: "POST", bearerToken: destination.token
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyJSON

            let (_, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else {
                throw SyncClientError.httpStatus(0)
            }
            if !(200...299).contains(http.statusCode) {
                print("[sync] \(path) returned status \(http.statusCode)")
                await recordFailure(path: path, message: "HTTP \(http.statusCode)")
                return false
            }
            await recordSuccess(path: path)
            return true
        } catch {
            print("[sync] \(path) failed: \(error)")
            await recordFailure(path: path, message: OperatorFacingError.message(error))
            return false
        }
    }

    private struct Destination: Sendable {
        let endpoint: String
        let token: String
    }

    private func destinationSnapshot() throws -> Destination {
        let rawBase = syncServerURL().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBase.isEmpty else { throw SyncClientError.notConfigured }
        return Destination(endpoint: try PendingPushQueue.normalizedEndpoint(rawBase), token: syncAPIToken())
    }

    private func getPage<T: Decodable & Sendable>(
        path: String,
        limit: Int,
        cursor: SyncPullCursor?
    ) async throws -> SyncPullPage<T> {
        var request = try makeRequest(
            path: path,
            method: "GET",
            queryItems: SyncQuery.listItems(limit: limit, cursor: cursor)
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncClientError.httpStatus(0)
        }
        guard (200...299).contains(http.statusCode) else {
            throw SyncClientError.httpStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rows = try decoder.decode([T].self, from: data)
        let boundary = Self.cursorBoundary(from: http)
        return SyncPullPage(
            rows: rows,
            serverBoundary: boundary,
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

    /// Shared base URL + optional Bearer token for POST and GET. Delegates to the shared
    /// `SyncTransportPolicy.makeRequest` so the transport rules cannot drift per client.
    func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        let rawBase = syncServerURL().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBase.isEmpty else {
            throw SyncClientError.notConfigured
        }
        do {
            return try SyncTransportPolicy.makeRequest(
                baseURL: rawBase,
                path: path,
                method: method,
                queryItems: queryItems,
                bearerToken: syncAPIToken()
            )
        } catch {
            throw SyncClientError.invalidURL(path)
        }
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
