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
        try await UserMemory.query(on: req.db).sort(\.$updatedAt, .descending).limit(100).all()
    }

    app.get("api", "channels") { req async throws -> [ChannelContext] in
        try await ChannelContext.query(on: req.db).sort(\.$updatedAt, .descending).limit(100).all()
    }

    app.get { req async throws -> View in
        let runtime = req.application.botRuntime
        let metrics = await runtime.metricsSnapshot()
        return try await req.view.render(
            "status",
            [
                "discordState": metrics.discordState,
                "botUserId": metrics.discordBotUserId,
                "messagesIngested": "\(metrics.messagesIngested)",
                "liveIngestCount": "\(metrics.liveIngestCount)",
                "inferenceCalls": "\(metrics.inferenceCalls)",
                "inferenceFailures": "\(metrics.inferenceFailures)"
            ]
        )
    }
}
