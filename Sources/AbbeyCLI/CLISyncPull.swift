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
            async let usersTask = SyncPageDrain.run(
                initialCursor: cursors[.users] ?? .initial, attemptStartedAt: startedAt
            ) { try await client.fetchUsersPage(cursor: $0) }
            async let channelsTask = SyncPageDrain.run(
                initialCursor: cursors[.channels] ?? .initial, attemptStartedAt: startedAt
            ) { try await client.fetchChannelsPage(cursor: $0) }
            async let messagesTask = SyncPageDrain.run(
                initialCursor: cursors[.messages] ?? .initial, attemptStartedAt: startedAt
            ) { try await client.fetchMessagesPage(cursor: $0) }
            async let reputationTask = SyncPageDrain.run(
                initialCursor: cursors[.reputation] ?? .initial, attemptStartedAt: startedAt
            ) { try await client.fetchReputationPage(cursor: $0) }
            async let interactionsTask = SyncPageDrain.run(
                initialCursor: cursors[.interactions] ?? .initial, attemptStartedAt: startedAt
            ) { try await client.fetchInteractionsPage(cursor: $0) }
            async let equityTask = SyncPageDrain.run(
                initialCursor: cursors[.equity] ?? .initial, attemptStartedAt: startedAt
            ) { try await client.fetchEquityPage(cursor: $0) }

            let usersDrain = try await usersTask
            let channelsDrain = try await channelsTask
            let messagesDrain = try await messagesTask
            let reputationDrain = try await reputationTask
            let interactionsDrain = try await interactionsTask
            let equityDrain = try await equityTask

            let users = usersDrain.rows
            let channels = channelsDrain.rows
            let messages = messagesDrain.rows
            let reputation = reputationDrain.rows
            let interactions = interactionsDrain.rows
            let equity = equityDrain.rows

            let counts = try await ServerSyncApply.apply(
                users: users,
                channels: channels,
                messages: messages,
                reputation: reputation,
                interactions: interactions,
                equity: equity,
                on: runtime.database
            )

            var nextCursors = cursors
            nextCursors[.users] = usersDrain.nextCursor
            nextCursors[.channels] = channelsDrain.nextCursor
            nextCursors[.messages] = messagesDrain.nextCursor
            nextCursors[.reputation] = reputationDrain.nextCursor
            nextCursors[.interactions] = interactionsDrain.nextCursor
            nextCursors[.equity] = equityDrain.nextCursor

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

}
