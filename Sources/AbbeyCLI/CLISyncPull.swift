import AbbeyCore
import AbbeyServerKit
import Foundation

/// `/sync pull` — pull server rows into the CLI's Fluent database. Fetches the six list
/// endpoints with the persisted `?since=` cursor (`~/.abbey/cli-sync-cursor`) and applies
/// them via `ServerSyncApply`. Pair with `/sync push` for the CLI's write path; there is
/// still no CRDT merge.
enum CLISyncPull {
    /// Runs one pull. Returns the lines to print — pure enough to unit-test the messaging
    /// without a REPL. The cursor only advances after a fully successful pull.
    static func run(
        runtime: BotRuntime,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cursorStore: SyncCursorFileStore = SyncCursorFileStore()
    ) async -> [String] {
        guard let client = ServerSyncClient.fromEnvironment(environment) else {
            return [
                "Sync is not configured. Set ABBEY_SYNC_SERVER_URL (and ABBEY_SYNC_API_TOKEN",
                "if the server sets ABBEY_API_TOKEN) — same env vars the desktop uses."
            ]
        }

        let since = cursorStore.loadLastPullSuccess()
        // Stamp at pull *start* so rows written mid-pull are refetched next time.
        let startedAt = Date()

        do {
            let users = try await client.fetchUsers(since: since)
            let channels = try await client.fetchChannels(since: since)
            let messages = try await client.fetchMessages(since: since)
            let reputation = try await client.fetchReputation(since: since)
            let interactions = try await client.fetchInteractions(since: since)
            let equity = try await client.fetchEquity(since: since)

            let counts = try await ServerSyncApply.apply(
                users: users,
                channels: channels,
                messages: messages,
                reputation: reputation,
                interactions: interactions,
                equity: equity,
                on: runtime.database
            )

            do {
                try cursorStore.saveLastPullSuccess(startedAt)
            } catch {
                return [
                    "Pulled from \(client.baseURL): \(counts.summary).",
                    "Warning: could not persist the sync cursor (\(OperatorFacingError.message(error))) — next pull will refetch."
                ]
            }

            let scope = since.map { "since \(Self.format($0))" } ?? "full (no cursor)"
            return ["Pulled from \(client.baseURL) [\(scope)]: \(counts.summary)."]
        } catch {
            return [
                "Sync pull failed: \(OperatorFacingError.message(error))",
                "Cursor not advanced — the next pull retries the same window."
            ]
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
