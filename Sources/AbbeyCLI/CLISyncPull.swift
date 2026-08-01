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

        let cursorStore = cursorStore.fileURL == SyncCursorFileStore.defaultURL()
            ? SyncCursorFileStore(fileURL: SyncCursorFileStore.namespacedPullURL(endpoint: client.baseURL))
            : cursorStore

        let cursors = cursorStore.loadPullCursors()
        // Pull start is the upper cursor bound; a full entity page may hold it back to the
        // newest server change actually returned so later pulls drain the remaining rows.
        let startedAt = Date()

        do {
            async let usersTask = client.fetchUsersPage(cursor: cursors.users ?? .initial)
            async let channelsTask = client.fetchChannelsPage(cursor: cursors.channels ?? .initial)
            async let messagesTask = client.fetchMessagesPage(cursor: cursors.messages ?? .initial)
            async let reputationTask = client.fetchReputationPage(cursor: cursors.reputation ?? .initial)
            async let interactionsTask = client.fetchInteractionsPage(cursor: cursors.interactions ?? .initial)
            async let equityTask = client.fetchEquityPage(cursor: cursors.equity ?? .initial)

            let usersPage = try await usersTask
            let channelsPage = try await channelsTask
            let messagesPage = try await messagesTask
            let reputationPage = try await reputationTask
            let interactionsPage = try await interactionsTask
            let equityPage = try await equityTask

            let users = usersPage.rows
            let channels = channelsPage.rows
            let messages = messagesPage.rows
            let reputation = reputationPage.rows
            let interactions = interactionsPage.rows
            let equity = equityPage.rows

            let counts = try await ServerSyncApply.apply(
                users: users,
                channels: channels,
                messages: messages,
                reputation: reputation,
                interactions: interactions,
                equity: equity,
                on: runtime.database
            )

            let effectiveLimit = 500
            var nextCursors = cursors
            nextCursors.users = nextCursor(
                previous: cursors.users ?? .initial, page: usersPage,
                startedAt: startedAt, limit: effectiveLimit
            )
            nextCursors.channels = nextCursor(
                previous: cursors.channels ?? .initial, page: channelsPage,
                startedAt: startedAt, limit: effectiveLimit
            )
            nextCursors.messages = nextCursor(
                previous: cursors.messages ?? .initial, page: messagesPage,
                startedAt: startedAt, limit: effectiveLimit
            )
            nextCursors.reputation = nextCursor(
                previous: cursors.reputation ?? .initial, page: reputationPage,
                startedAt: startedAt, limit: effectiveLimit
            )
            nextCursors.interactions = nextCursor(
                previous: cursors.interactions ?? .initial, page: interactionsPage,
                startedAt: startedAt, limit: effectiveLimit
            )
            nextCursors.equity = nextCursor(
                previous: cursors.equity ?? .initial, page: equityPage,
                startedAt: startedAt, limit: effectiveLimit
            )

            do {
                try cursorStore.applyPullOutcome(nextCursors: nextCursors, succeeded: true)
            } catch {
                return [
                    "Pulled from \(client.baseURL): \(counts.summary).",
                    "Warning: could not persist the sync cursor (\(OperatorFacingError.message(error))) — next pull will refetch."
                ]
            }

            let scope = cursors.earliestChangedAt.map { "incremental from \(Self.format($0))" }
                ?? "full (compound cursor bootstrap)"
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

    private static func nextCursor<Row: Sendable>(
        previous: SyncPullCursor,
        page: SyncPullPage<Row>,
        startedAt: Date,
        limit: Int
    ) -> SyncPullCursor? {
        IncrementalSyncCursor.next(
            previous: previous,
            attemptStartedAt: startedAt,
            limit: limit,
            rowCount: page.rows.count,
            serverBoundary: page.serverBoundary,
            serverHighWatermark: page.serverHighWatermark
        )
    }
}
