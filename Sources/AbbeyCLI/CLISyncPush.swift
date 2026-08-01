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
    typealias MessageRow = (
        createdAt: Date?,
        discordMessageId: String,
        content: String,
        channelId: String,
        guildId: String,
        authorId: String,
        deletedAt: Date?
    )
    typealias MemoryRow = (
        updatedAt: Date?,
        discordUserId: String,
        guildId: String,
        facts: [String],
        deletedAt: Date?
    )

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
        messages: [MessageRow],
        memories: [MemoryRow]
    ) -> Plan {
        let liveMessages = messages
            .filter { $0.deletedAt == nil }
            .sorted {
                let lhsDate = $0.createdAt ?? .distantPast
                let rhsDate = $1.createdAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return $0.discordMessageId < $1.discordMessageId
            }
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
            .sorted {
                let lhsDate = $0.updatedAt ?? .distantPast
                let rhsDate = $1.updatedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                if $0.guildId != $1.guildId { return $0.guildId < $1.guildId }
                return $0.discordUserId < $1.discordUserId
            }
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
/// Uses message/memory sidecars beside `~/.abbey/cli-sync-push-cursor` (independent of the
/// pull cursor). Each stream advances only after that stream fully succeeds.
/// Reputation/interactions/equity/tombstones are out of scope (see `CLISyncPushPlan`).
enum CLISyncPush {
    struct Source: Sendable {
        var messages: @Sendable (Date?) async throws -> [CLISyncPushPlan.MessageRow]
        var memories: @Sendable (Date?) async throws -> [CLISyncPushPlan.MemoryRow]
    }

    struct Sink: Sendable {
        var baseURL: String
        /// Returns true when the server reports an idempotent duplicate.
        var pushMessage: @Sendable (CLISyncPushPlan.MessagePayload) async throws -> Bool
        var pushFact: @Sendable (CLISyncPushPlan.FactPayload) async throws -> Void
    }

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

        let cursorStore = cursorStore.fileURL == SyncCursorFileStore.defaultPushURL()
            ? SyncCursorFileStore(fileURL: SyncCursorFileStore.namespacedPushURL(endpoint: client.baseURL))
            : cursorStore

        let source = Source(
            messages: { since in try await selectMessages(since: since, on: runtime.database) },
            memories: { since in try await selectMemories(since: since, on: runtime.database) }
        )
        let sink = Sink(
            baseURL: client.baseURL,
            pushMessage: { message in
                let result = try await client.pushIngest(
                    discordMessageId: message.discordMessageId,
                    content: message.content,
                    channelId: message.channelId,
                    guildId: message.guildId,
                    authorId: message.authorId
                )
                return result.duplicate
            },
            pushFact: { fact in
                try await client.pushRemember(userId: fact.userId, guildId: fact.guildId, fact: fact.fact)
            }
        )
        return await execute(
            source: source,
            sink: sink,
            cursorStore: cursorStore,
            startedAt: Date()
        )
    }

    /// Executes the two push streams independently. This dependency-injected seam keeps
    /// large-batch/resume behavior deterministic in tests without opening sockets.
    static func execute(
        source: Source,
        sink: Sink,
        cursorStore: SyncCursorFileStore,
        startedAt: Date
    ) async -> [String] {
        let messageSince = cursorStore.loadLastSuccess(for: .messages)
        let memorySince = cursorStore.loadLastSuccess(for: .memories)

        var messagesPushed = 0
        var factsPushed = 0
        var duplicatesSkipped = 0
        var messageFailure: String?
        var memoryFailure: String?

        do {
            let rows = try await source.messages(messageSince)
            let messages = CLISyncPushPlan.build(messages: rows, memories: []).messages
            for message in messages {
                if try await sink.pushMessage(message) {
                    duplicatesSkipped += 1
                } else {
                    messagesPushed += 1
                }
            }
            try cursorStore.saveLastSuccess(startedAt, for: .messages)
        } catch {
            messageFailure = OperatorFacingError.message(error)
        }

        do {
            let rows = try await source.memories(memorySince)
            let facts = CLISyncPushPlan.build(messages: [], memories: rows).facts
            for fact in facts {
                try await sink.pushFact(fact)
                factsPushed += 1
            }
            try cursorStore.saveLastSuccess(startedAt, for: .memories)
        } catch {
            memoryFailure = OperatorFacingError.message(error)
        }

        if messageFailure == nil, memoryFailure == nil {
            let messageScope = messageSince.map { "since \(Self.format($0))" } ?? "full"
            let memoryScope = memorySince.map { "since \(Self.format($0))" } ?? "full"
            return [
                "Pushed to \(sink.baseURL) [messages: \(messageScope); memories: \(memoryScope)]: \(messagesPushed) messages, \(factsPushed) facts (\(duplicatesSkipped) duplicates skipped)."
            ]
        }

        var failures: [String] = []
        if let messageFailure { failures.append("messages: \(messageFailure)") }
        if let memoryFailure { failures.append("memories: \(memoryFailure)") }
        return [
            "Sync push partially failed after \(messagesPushed) messages and \(factsPushed) facts (\(duplicatesSkipped) duplicates skipped): \(failures.joined(separator: "; ")).",
            "Each failed stream kept its cursor; successful stream cursors advanced independently."
        ]
    }

    private static func selectMessages(
        since: Date?,
        on db: any Database
    ) async throws -> [CLISyncPushPlan.MessageRow] {
        var query = GuildMessage.query(on: db)
        if let since {
            // Inclusive overlap avoids dropping rows tied exactly to the cursor; ingest is
            // idempotent by discord message id, so replay is safe.
            query = query.filter(\.$createdAt >= since)
        }
        let rows = try await query.sort(\.$createdAt, .ascending).all()
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
    ) async throws -> [CLISyncPushPlan.MemoryRow] {
        var query = UserMemory.query(on: db)
        if let since {
            // Identical facts are idempotent server-side, so inclusive overlap is safer
            // than skipping records whose timestamp ties the persisted cursor.
            query = query.filter(\.$updatedAt >= since)
        }
        let rows = try await query.sort(\.$updatedAt, .ascending).all()
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
