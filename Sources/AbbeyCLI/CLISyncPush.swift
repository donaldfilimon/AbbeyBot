import AbbeyCore
import AbbeyServerKit
import Fluent
import Foundation

/// Pure selection + payload shaping for `/sync push`. Unit-testable without HTTP or Fluent.
///
/// Scope: messages + user memory facts only. Reputation/interactions are re-derived by
/// server-side ingest (pushing them would double-count). Equity and tombstones have no CLI
/// write surface (`/clear` is non-destructive).
enum CLISyncPushPlan {
    struct MessagePayload: Equatable, Sendable {
        var discordMessageId: String
        var content: String
        var channelId: String
        var guildId: String
        var authorId: String
    }

    struct FactPayload: Equatable, Sendable {
        var userId: String
        var guildId: String
        var fact: String
    }

    struct Plan: Equatable, Sendable {
        var messages: [MessagePayload]
        var facts: [FactPayload]
    }

    /// Build push payloads from already-fetched local rows. Messages are ordered by
    /// `createdAt` ascending (oldest first) so the server timeline stays coherent; facts
    /// are expanded per-user in fact-array order. Empty / whitespace-only facts are skipped.
    static func build(
        messages: [(createdAt: Date?, discordMessageId: String, content: String, channelId: String, guildId: String, authorId: String, deletedAt: Date?)],
        memories: [(updatedAt: Date?, discordUserId: String, guildId: String, facts: [String], deletedAt: Date?)]
    ) -> Plan {
        let liveMessages = messages
            .filter { $0.deletedAt == nil }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            .map {
                MessagePayload(
                    discordMessageId: $0.discordMessageId,
                    content: $0.content,
                    channelId: $0.channelId,
                    guildId: $0.guildId,
                    authorId: $0.authorId
                )
            }

        var facts: [FactPayload] = []
        let liveMemories = memories
            .filter { $0.deletedAt == nil }
            .sorted { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        for memory in liveMemories {
            for fact in memory.facts {
                let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                facts.append(FactPayload(
                    userId: memory.discordUserId,
                    guildId: memory.guildId,
                    fact: trimmed
                ))
            }
        }

        return Plan(messages: liveMessages, facts: facts)
    }
}

/// `/sync push` — push CLI-local messages and memory facts to the configured sync server.
/// Uses `~/.abbey/cli-sync-push-cursor` (independent of the pull cursor). Cursor advances
/// only after a fully successful push. Reputation/interactions/equity/tombstones are out
/// of scope for this command (see `CLISyncPushPlan`).
enum CLISyncPush {
    static func run(
        runtime: BotRuntime,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cursorStore: SyncCursorFileStore = SyncCursorFileStore(fileURL: SyncCursorFileStore.defaultPushURL())
    ) async -> [String] {
        guard let client = ServerSyncClient.fromEnvironment(environment) else {
            return [
                "Sync is not configured. Set ABBEY_SYNC_SERVER_URL (and ABBEY_SYNC_API_TOKEN",
                "if the server sets ABBEY_API_TOKEN) — same env vars the desktop uses."
            ]
        }

        let since = cursorStore.loadLastSuccess()
        let startedAt = Date()

        do {
            let messageRows = try await selectMessages(since: since, on: runtime.database)
            let memoryRows = try await selectMemories(since: since, on: runtime.database)
            let plan = CLISyncPushPlan.build(messages: messageRows, memories: memoryRows)

            var messagesPushed = 0
            var factsPushed = 0
            var duplicatesSkipped = 0

            for message in plan.messages {
                let result = try await client.pushIngest(
                    discordMessageId: message.discordMessageId,
                    content: message.content,
                    channelId: message.channelId,
                    guildId: message.guildId,
                    authorId: message.authorId
                )
                if result.duplicate {
                    duplicatesSkipped += 1
                } else {
                    messagesPushed += 1
                }
            }

            for fact in plan.facts {
                try await client.pushRemember(
                    userId: fact.userId,
                    guildId: fact.guildId,
                    fact: fact.fact
                )
                factsPushed += 1
            }

            do {
                try cursorStore.saveLastSuccess(startedAt)
            } catch {
                return [
                    "Pushed to \(client.baseURL): \(messagesPushed) messages, \(factsPushed) facts (\(duplicatesSkipped) duplicates skipped).",
                    "Warning: could not persist the push cursor (\(OperatorFacingError.message(error))) — next push will refetch."
                ]
            }

            let scope = since.map { "since \(Self.format($0))" } ?? "full (no cursor)"
            return [
                "Pushed to \(client.baseURL) [\(scope)]: \(messagesPushed) messages, \(factsPushed) facts (\(duplicatesSkipped) duplicates skipped)."
            ]
        } catch {
            return [
                "Sync push failed: \(OperatorFacingError.message(error))",
                "Cursor not advanced — the next push retries the same window."
            ]
        }
    }

    private static func selectMessages(
        since: Date?,
        on db: any Database
    ) async throws -> [(createdAt: Date?, discordMessageId: String, content: String, channelId: String, guildId: String, authorId: String, deletedAt: Date?)] {
        var query = GuildMessage.query(on: db)
        if let since {
            query = query.filter(\.$createdAt > since)
        }
        let rows = try await query.sort(\.$createdAt, .ascending).limit(500).all()
        return rows.map {
            (
                createdAt: $0.createdAt,
                discordMessageId: $0.discordMessageId,
                content: $0.content,
                channelId: $0.channelId,
                guildId: $0.guildId,
                authorId: $0.authorId,
                deletedAt: $0.deletedAt
            )
        }
    }

    private static func selectMemories(
        since: Date?,
        on db: any Database
    ) async throws -> [(updatedAt: Date?, discordUserId: String, guildId: String, facts: [String], deletedAt: Date?)] {
        var query = UserMemory.query(on: db)
        if let since {
            query = query.filter(\.$updatedAt > since)
        }
        let rows = try await query.sort(\.$updatedAt, .ascending).limit(500).all()
        return rows.map {
            (
                updatedAt: $0.updatedAt,
                discordUserId: $0.discordUserId,
                guildId: $0.guildId,
                facts: $0.facts,
                deletedAt: $0.deletedAt
            )
        }
    }

    private static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
