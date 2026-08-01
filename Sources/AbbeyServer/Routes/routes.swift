import AbbeyCore
import AbbeyServerKit
import Foundation
import Vapor

struct HealthDTO: Content {
    var status: String
    var discord: String
}

struct StatusDTO: Content {
    var databaseDialect: String
    var discordState: String
    var botUserId: String
    var users: Int
    var channels: Int
    var messages: Int
    var reputationEvents: Int
    var equityIdeas: Int
    var messagesIngested: Int
    var liveIngestCount: Int
    var inferenceCalls: Int
    var inferenceFailures: Int
    /// Last EventSub `stream.online`/`stream.offline` observation this process; nil if never seen.
    var twitchStreamLive: Bool?
}

struct IngestRequestDTO: Content {
    var content: String
    var channelId: String
    var guildId: String
    var authorId: String
    var discordMessageId: String?
}

struct IngestResponseDTO: Content {
    var ok: Bool
    var discordMessageId: String
    /// True when the id was already present and ingest was skipped (no rescore / no second row).
    var duplicate: Bool
}

struct RememberRequestDTO: Content {
    var guildId: String
    var userId: String
    var fact: String
}

struct ForgetRequestDTO: Content {
    var guildId: String
    var userId: String
    var index: Int
}

struct TombstoneUserRequestDTO: Content {
    var guildId: String
    var userId: String
}

struct TombstoneChannelRequestDTO: Content {
    var guildId: String
    var channelId: String
}

struct TombstoneMessageRequestDTO: Content {
    var discordMessageId: String
}

struct TombstoneIdRequestDTO: Content {
    var id: UUID
}

struct TombstoneEquityRequestDTO: Content {
    var symbol: String
}

struct SyncStatusReportDTO: Content {
    var lastPullAt: Date?
    var lastPullError: String?
    var lastPushAt: Date?
    var lastPushError: String?
    var pendingPushCount: Int
}

struct OkDTO: Content {
    var ok: Bool
}

private func clampedLimit(_ req: Request, default defaultLimit: Int = 100, max maxLimit: Int = 500) -> Int {
    let raw = req.query[Int.self, at: "limit"] ?? defaultLimit
    return min(max(raw, 1), maxLimit)
}

/// Compound incremental cursor. `after` is meaningful only with `since`; legacy clients
/// that send only `since` retain timestamp-only strict-`>` behavior.
private func syncCursorParam(_ req: Request) -> SyncPullCursor? {
    guard let raw = req.query[Double.self, at: SyncPullCursorWire.timeQuery], raw >= 0 else {
        return nil
    }
    return SyncPullCursor(
        changedAt: Date(timeIntervalSince1970: raw),
        stableID: req.query[String.self, at: SyncPullCursorWire.idQuery]
    )
}

private func latestChange(_ original: Date?, _ deletedAt: Date?) -> Date? {
    [original, deletedAt].compactMap { $0 }.max()
}

/// Preserve the public JSON-array body while publishing a full-precision server cursor in
/// headers. Sync clients consume the headers; the SPA and existing callers ignore them.
private func syncListResponse<T: Content>(
    _ rows: [T],
    boundary: SyncPullCursor?,
    highWatermark: Date
) throws -> Response {
    let response = Response(status: .ok)
    try response.content.encode(rows)
    response.headers.replaceOrAdd(
        name: SyncPullCursorWire.highWatermarkHeader,
        value: String(highWatermark.timeIntervalSince1970)
    )
    if let boundary {
        response.headers.replaceOrAdd(
            name: SyncPullCursorWire.timeHeader,
            value: String(boundary.changedAt.timeIntervalSince1970)
        )
        if let stableID = boundary.stableID {
            response.headers.replaceOrAdd(name: SyncPullCursorWire.idHeader, value: stableID)
        }
    }
    return response
}

func routes(_ app: Application) throws {
    TwitchEventSubRoutes.register(on: app)
    SocialRoutes.register(on: app)

    app.get("health") { req async -> HealthDTO in
        let runtime = req.application.botRuntime
        let state = await runtime.discordState
        return HealthDTO(status: "ok", discord: state.rawValue)
    }

    app.get("dashboard") { req async throws -> Response in
        let indexPath = resourcesPublicDirectory().appendingPathComponent("index.html").path
        guard FileManager.default.fileExists(atPath: indexPath) else {
            throw Abort(.notFound, reason: "Dashboard not built — run `bun run build` (or npm) in web/ first")
        }
        return try await req.fileio.asyncStreamFile(at: indexPath)
    }

    app.get("api", "metrics") { req async throws -> MetricsDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        return await req.application.botRuntime.metricsSnapshot()
    }

    app.get("api", "status") { req async throws -> StatusDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let runtime = req.application.botRuntime
        let metrics = await runtime.metricsSnapshot()
        let counts = try await StatusRepository.counts(on: req.db)
        let twitchStreamLive = await runtime.twitchStreamLive
        return StatusDTO(
            databaseDialect: req.application.databaseDialect,
            discordState: metrics.discordState,
            botUserId: metrics.discordBotUserId,
            users: counts.users,
            channels: counts.channels,
            messages: counts.messages,
            reputationEvents: counts.reputationEvents,
            equityIdeas: counts.equityIdeas,
            messagesIngested: metrics.messagesIngested,
            liveIngestCount: metrics.liveIngestCount,
            inferenceCalls: metrics.inferenceCalls,
            inferenceFailures: metrics.inferenceFailures,
            twitchStreamLive: twitchStreamLive
        )
    }

    app.post("api", "ingest") { req async throws -> IngestResponseDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(IngestRequestDTO.self)
        let content = body.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw Abort(.badRequest, reason: "content must be non-empty")
        }
        let messageId = body.discordMessageId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedId = (messageId?.isEmpty == false) ? messageId! : UUID().uuidString
        let outcome = await req.application.botRuntime.ingestMessageOutcome(
            content: content,
            channelId: body.channelId.isEmpty ? "api" : body.channelId,
            guildId: body.guildId.isEmpty ? "api" : body.guildId,
            authorId: body.authorId.isEmpty ? "api" : body.authorId,
            discordMessageId: resolvedId
        )
        switch outcome {
        case .inserted:
            return IngestResponseDTO(ok: true, discordMessageId: resolvedId, duplicate: false)
        case .duplicate:
            return IngestResponseDTO(ok: true, discordMessageId: resolvedId, duplicate: true)
        case .failed:
            throw Abort(.serviceUnavailable, reason: "message persistence failed; retry this request")
        }
    }

    // Keyed shared-state reads/writes for the desktop app's sync client. Distinct from
    // the "recent N" list endpoints below, which aren't keyed by a specific user/channel.
    app.get("api", "state", "user") { req async throws -> UserStateDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        guard let guildId = req.query[String.self, at: "guildId"], !guildId.isEmpty,
              let userId = req.query[String.self, at: "userId"], !userId.isEmpty
        else {
            throw Abort(.badRequest, reason: "guildId and userId query params are required")
        }
        return await req.application.botRuntime.userState(userId: userId, guildId: guildId)
    }

    app.get("api", "state", "channel") { req async throws -> ChannelStateDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        guard let guildId = req.query[String.self, at: "guildId"], !guildId.isEmpty,
              let channelId = req.query[String.self, at: "channelId"], !channelId.isEmpty
        else {
            throw Abort(.badRequest, reason: "guildId and channelId query params are required")
        }
        return await req.application.botRuntime.channelState(channelId: channelId, guildId: guildId)
    }

    app.post("api", "state", "remember") { req async throws -> OkDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(RememberRequestDTO.self)
        let fact = body.fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else {
            throw Abort(.badRequest, reason: "fact must be non-empty")
        }
        try await req.application.botRuntime.remember(userId: body.userId, guildId: body.guildId, fact: fact)
        return OkDTO(ok: true)
    }

    app.post("api", "state", "forget") { req async throws -> OkDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(ForgetRequestDTO.self)
        do {
            try await req.application.botRuntime.forget(userId: body.userId, guildId: body.guildId, index: body.index)
            return OkDTO(ok: true)
        } catch MemoryForgetError.noMemory {
            throw Abort(.notFound, reason: "no memory for that user")
        } catch MemoryForgetError.invalidIndex {
            throw Abort(.badRequest, reason: "invalid fact index")
        }
    }

    app.post("api", "state", "tombstone", "user") { req async throws -> OkDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(TombstoneUserRequestDTO.self)
        do {
            try await req.application.botRuntime.tombstoneUser(userId: body.userId, guildId: body.guildId)
            return OkDTO(ok: true)
        } catch MemoryTombstoneError.noMemory {
            throw Abort(.notFound, reason: "no memory for that user")
        }
    }

    app.post("api", "state", "tombstone", "channel") { req async throws -> OkDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(TombstoneChannelRequestDTO.self)
        do {
            try await req.application.botRuntime.tombstoneChannel(channelId: body.channelId, guildId: body.guildId)
            return OkDTO(ok: true)
        } catch ChannelTombstoneError.noChannel {
            throw Abort(.notFound, reason: "no channel context for that channel")
        }
    }

    app.post("api", "state", "tombstone", "message") { req async throws -> OkDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(TombstoneMessageRequestDTO.self)
        do {
            try await req.application.botRuntime.tombstoneMessage(discordMessageId: body.discordMessageId)
            return OkDTO(ok: true)
        } catch MessageTombstoneError.noMessage {
            throw Abort(.notFound, reason: "no message for that discordMessageId")
        }
    }

    app.post("api", "state", "tombstone", "reputation") { req async throws -> OkDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(TombstoneIdRequestDTO.self)
        do {
            try await req.application.botRuntime.tombstoneReputation(id: body.id)
            return OkDTO(ok: true)
        } catch ReputationTombstoneError.noEvent {
            throw Abort(.notFound, reason: "no reputation event for that id")
        }
    }

    app.post("api", "state", "tombstone", "interaction") { req async throws -> OkDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(TombstoneIdRequestDTO.self)
        do {
            try await req.application.botRuntime.tombstoneInteraction(id: body.id)
            return OkDTO(ok: true)
        } catch InteractionTombstoneError.noLog {
            throw Abort(.notFound, reason: "no interaction log for that id")
        }
    }

    app.post("api", "state", "tombstone", "equity") { req async throws -> OkDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(TombstoneEquityRequestDTO.self)
        do {
            try await req.application.botRuntime.tombstoneEquity(symbol: body.symbol)
            return OkDTO(ok: true)
        } catch EquityTombstoneError.noIdea {
            throw Abort(.notFound, reason: "no equity idea for that symbol")
        }
    }

    app.post("api", "state", "sync-status") { req async throws -> OkDTO in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let body = try req.content.decode(SyncStatusReportDTO.self)
        try await SyncStatusRepository.report(
            lastPullAt: body.lastPullAt,
            lastPullError: body.lastPullError,
            lastPushAt: body.lastPushAt,
            lastPushError: body.lastPushError,
            pendingPushCount: body.pendingPushCount,
            on: req.db
        )
        return OkDTO(ok: true)
    }

    app.get("api", "sync-status") { req async throws -> SyncStatusRecord in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        return try await SyncStatusRepository.current(on: req.db)
    }

    app.get("api", "users") { req async throws -> Response in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let highWatermark = Date()
        let cursor = syncCursorParam(req)
        let rows = try await MemoryRepository.recent(limit: clampedLimit(req), cursor: cursor, on: req.db)
        let boundary = rows.last.flatMap { row in
            row.updatedAt.map { SyncPullCursor(changedAt: $0, stableID: row.compositeKey) }
        }
        return try syncListResponse(rows, boundary: boundary, highWatermark: highWatermark)
    }

    app.get("api", "channels") { req async throws -> Response in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let highWatermark = Date()
        let cursor = syncCursorParam(req)
        let rows = try await ChannelRepository.recent(limit: clampedLimit(req), cursor: cursor, on: req.db)
        let boundary = rows.last.flatMap { row in
            row.updatedAt.map { SyncPullCursor(changedAt: $0, stableID: row.compositeKey) }
        }
        return try syncListResponse(rows, boundary: boundary, highWatermark: highWatermark)
    }

    app.get("api", "messages") { req async throws -> Response in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let highWatermark = Date()
        let cursor = syncCursorParam(req)
        let rows = try await MessageRepository.recent(limit: clampedLimit(req), cursor: cursor, on: req.db)
        let boundary = rows.last.flatMap { row in
            latestChange(row.createdAt, row.deletedAt).map {
                SyncPullCursor(changedAt: $0, stableID: row.discordMessageId)
            }
        }
        return try syncListResponse(rows, boundary: boundary, highWatermark: highWatermark)
    }

    app.get("api", "reputation") { req async throws -> Response in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let highWatermark = Date()
        let cursor = syncCursorParam(req)
        let rows = try await ReputationRepository.recent(limit: clampedLimit(req), cursor: cursor, on: req.db)
        let boundary: SyncPullCursor? = rows.last.flatMap { row -> SyncPullCursor? in
            guard let id = row.id, let changedAt = latestChange(row.createdAt, row.deletedAt) else { return nil }
            return SyncPullCursor(changedAt: changedAt, stableID: id.uuidString)
        }
        return try syncListResponse(rows, boundary: boundary, highWatermark: highWatermark)
    }

    app.get("api", "interactions") { req async throws -> Response in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let highWatermark = Date()
        let cursor = syncCursorParam(req)
        let rows = try await InteractionRepository.recent(limit: clampedLimit(req), cursor: cursor, on: req.db)
        let boundary: SyncPullCursor? = rows.last.flatMap { row -> SyncPullCursor? in
            guard let id = row.id, let changedAt = latestChange(row.createdAt, row.deletedAt) else { return nil }
            return SyncPullCursor(changedAt: changedAt, stableID: id.uuidString)
        }
        return try syncListResponse(rows, boundary: boundary, highWatermark: highWatermark)
    }

    app.get("api", "equity") { req async throws -> Response in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let highWatermark = Date()
        let cursor = syncCursorParam(req)
        let rows = try await EquityRepository.recent(limit: clampedLimit(req), cursor: cursor, on: req.db)
        let boundary = rows.last.flatMap { row in
            latestChange(row.generatedAt, row.deletedAt).map {
                SyncPullCursor(changedAt: $0, stableID: row.symbol)
            }
        }
        return try syncListResponse(rows, boundary: boundary, highWatermark: highWatermark)
    }

    app.get { req async throws -> View in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        let runtime = req.application.botRuntime
        let metrics = await runtime.metricsSnapshot()
        let counts = try await StatusRepository.counts(on: req.db)
        let indexPath = resourcesPublicDirectory().appendingPathComponent("index.html").path
        let dashboardAvailable = FileManager.default.fileExists(atPath: indexPath)
        return try await req.view.render(
            "status",
            [
                "discordState": leafDiscordStateLabel(metrics.discordState),
                "botUserId": metrics.discordBotUserId,
                "databaseDialect": req.application.databaseDialect,
                "messagesIngested": "\(metrics.messagesIngested)",
                "liveIngestCount": "\(metrics.liveIngestCount)",
                "inferenceCalls": "\(metrics.inferenceCalls)",
                "inferenceFailures": "\(metrics.inferenceFailures)",
                "userCount": "\(counts.users)",
                "channelCount": "\(counts.channels)",
                "messageCount": "\(counts.messages)",
                "reputationEventCount": "\(counts.reputationEvents)",
                "equityIdeaCount": "\(counts.equityIdeas)",
                "dashboardAvailable": dashboardAvailable ? "true" : ""
            ]
        )
    }
}

/// Leaf-only title case for Discord wire states (`connected` → `Connected`).
private func leafDiscordStateLabel(_ raw: String) -> String {
    DiscordConnectionState(rawValue: raw)?.displayName ?? raw.capitalized
}
