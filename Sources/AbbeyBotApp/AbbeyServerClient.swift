import Foundation
import AbbeyCore

/// Best-effort HTTP client that mirrors desktop SwiftData writes to the running
/// AbbeyServer, so the CLI/server share state with this app.
///
/// This client is deliberately non-throwing to callers: every method swallows
/// its own errors and logs them, and every call is expected to be fired from a
/// detached/unstructured `Task` at the call site so it never blocks the caller
/// or the main actor. Sync is "off" (a silent no-op) whenever
/// `AppConfig.shared.syncServerURL` is empty.
struct AbbeyServerClient: Sendable {
    static let shared = AbbeyServerClient()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

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

    private func post(path: String, body: [String: String]) async {
        let objectBody = body.mapValues { $0 as Any }
        await post(path: path, jsonObjectBody: objectBody)
    }

    private func post(path: String, body: [String: JSONValue]) async {
        let objectBody = body.mapValues { $0.jsonObject }
        await post(path: path, jsonObjectBody: objectBody)
    }

    private func post(path: String, jsonObjectBody: [String: Any]) async {
        let rawBase = AppConfig.shared.syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawBase.isEmpty else {
            // Sync is unconfigured — silently no-op.
            return
        }
        let base = rawBase.hasSuffix("/") ? String(rawBase.dropLast()) : rawBase
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: base + suffix) else {
            print("[sync] invalid syncServerURL, skipping \(path)")
            await recordFailure(path: path, message: "invalid syncServerURL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = AppConfig.shared.syncAPIToken
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonObjectBody)
        } catch {
            print("[sync] failed to encode body for \(path): \(error)")
            await recordFailure(path: path, message: "encode failed")
            return
        }

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[sync] \(path) returned status \(http.statusCode)")
                await recordFailure(path: path, message: "HTTP \(http.statusCode)")
            } else {
                await recordSuccess(path: path)
            }
        } catch {
            print("[sync] \(path) failed: \(error)")
            await recordFailure(path: path, message: error.localizedDescription)
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
