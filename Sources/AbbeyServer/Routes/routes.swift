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

struct OkDTO: Content {
    var ok: Bool
}

private func clampedLimit(_ req: Request, default defaultLimit: Int = 100, max maxLimit: Int = 500) -> Int {
    let raw = req.query[Int.self, at: "limit"] ?? defaultLimit
    return min(max(raw, 1), maxLimit)
}

func routes(_ app: Application) throws {
    TwitchEventSubRoutes.register(on: app)

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

    app.get("api", "metrics") { req async -> MetricsDTO in
        await req.application.botRuntime.metricsSnapshot()
    }

    app.get("api", "status") { req async throws -> StatusDTO in
        let runtime = req.application.botRuntime
        let metrics = await runtime.metricsSnapshot()
        let counts = try await StatusRepository.counts(on: req.db)
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
            inferenceFailures: metrics.inferenceFailures
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
        await req.application.botRuntime.ingestMessage(
            content: content,
            channelId: body.channelId.isEmpty ? "api" : body.channelId,
            guildId: body.guildId.isEmpty ? "api" : body.guildId,
            authorId: body.authorId.isEmpty ? "api" : body.authorId,
            discordMessageId: resolvedId
        )
        return IngestResponseDTO(ok: true, discordMessageId: resolvedId)
    }

    // Keyed shared-state reads/writes for the desktop app's sync client. Distinct from
    // the "recent N" list endpoints below, which aren't keyed by a specific user/channel.
    app.get("api", "state", "user") { req async throws -> UserStateDTO in
        guard let guildId = req.query[String.self, at: "guildId"], !guildId.isEmpty,
              let userId = req.query[String.self, at: "userId"], !userId.isEmpty
        else {
            throw Abort(.badRequest, reason: "guildId and userId query params are required")
        }
        return await req.application.botRuntime.userState(userId: userId, guildId: guildId)
    }

    app.get("api", "state", "channel") { req async throws -> ChannelStateDTO in
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

    app.get("api", "users") { req async throws -> [UserMemory] in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        return try await MemoryRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "channels") { req async throws -> [ChannelContext] in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        return try await ChannelRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "messages") { req async throws -> [GuildMessage] in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        return try await MessageRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "reputation") { req async throws -> [ReputationEvent] in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        return try await ReputationRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "interactions") { req async throws -> [InteractionLog] in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        return try await InteractionRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "equity") { req async throws -> [EquityIdea] in
        try AbbeyAPIAuth.requireTokenIfConfigured(req)
        return try await EquityRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get { req async throws -> View in
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
