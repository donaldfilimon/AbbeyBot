import AbbeyCore
import Vapor

struct MetricsDTO: Content {
    var messagesIngested: Int
    var reputationEvents: Int
    var consolidations: String
    var inferenceCalls: Int
    var inferenceFailures: Int
    var liveIngestCount: Int
    var discordState: String
    var discordBotUserId: String
    var lastInferenceError: String
}

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

private func clampedLimit(_ req: Request, default defaultLimit: Int = 100, max maxLimit: Int = 500) -> Int {
    let raw = req.query[Int.self, at: "limit"] ?? defaultLimit
    return min(max(raw, 1), maxLimit)
}

func routes(_ app: Application) throws {
    app.get("health") { req async -> HealthDTO in
        let runtime = req.application.botRuntime
        let state = await runtime.discordState
        return HealthDTO(status: "ok", discord: state.rawValue)
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

    app.get("api", "users") { req async throws -> [UserMemory] in
        try await MemoryRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "channels") { req async throws -> [ChannelContext] in
        try await ChannelRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "messages") { req async throws -> [GuildMessage] in
        try await MessageRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "reputation") { req async throws -> [ReputationEvent] in
        try await ReputationRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "interactions") { req async throws -> [InteractionLog] in
        try await InteractionRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get("api", "equity") { req async throws -> [EquityIdea] in
        try await EquityRepository.recent(limit: clampedLimit(req), on: req.db)
    }

    app.get { req async throws -> View in
        let runtime = req.application.botRuntime
        let metrics = await runtime.metricsSnapshot()
        let counts = try await StatusRepository.counts(on: req.db)
        return try await req.view.render(
            "status",
            [
                "discordState": metrics.discordState,
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
                "equityIdeaCount": "\(counts.equityIdeas)"
            ]
        )
    }
}
