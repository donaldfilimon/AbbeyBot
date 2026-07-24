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

    app.get("api", "users") { req async throws -> [UserMemory] in
        let limit = clampedLimit(req)
        return try await UserMemory.query(on: req.db).sort(\.$updatedAt, .descending).limit(limit).all()
    }

    app.get("api", "channels") { req async throws -> [ChannelContext] in
        let limit = clampedLimit(req)
        return try await ChannelContext.query(on: req.db).sort(\.$updatedAt, .descending).limit(limit).all()
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
                "reputationEventCount": "\(counts.reputationEvents)"
            ]
        )
    }
}
