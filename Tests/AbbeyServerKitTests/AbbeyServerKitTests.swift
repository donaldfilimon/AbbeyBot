import AbbeyServerKit
import Foundation
import Testing
import Vapor

@Suite("AbbeyServerKit sqlite-memory", .serialized)
struct AbbeyServerKitTests {
    private func withRuntime<T: Sendable>(
        _ body: @Sendable (Application, BotRuntime) async throws -> T
    ) async throws -> T {
        unsetenv("DISCORD_BOT_TOKEN")
        unsetenv("DISCORD_DEV_GUILD_ID")
        setenv("DATABASE_URL", "sqlite://memory", 1)

        let app = try await Application.make(.testing)
        do {
            let runtime = try await configureRuntime(app, defaultDatabaseURL: "sqlite://memory")
            let result = try await body(app, runtime)
            try await app.asyncShutdown()
            return result
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    @Test func configureRuntimeUsesSqliteMemoryDialect() async throws {
        try await withRuntime { app, _ in
            #expect(app.databaseDialect == "sqlite-memory")
        }
    }

    @Test func configureRuntimeFallsBackToSqliteWhenDefaultPostgresUnreachable() async throws {
        unsetenv("DISCORD_BOT_TOKEN")
        unsetenv("DISCORD_DEV_GUILD_ID")
        unsetenv("DATABASE_URL")
        let app = try await Application.make(.testing)
        do {
            // Port 1 is effectively never a Postgres listener; probe should fail fast.
            _ = try await configureRuntime(
                app,
                defaultDatabaseURL: "postgres://abbey:abbey@127.0.0.1:1/abbeybot"
            )
            #expect(app.databaseDialect == "sqlite-file")
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        setenv("DATABASE_URL", "sqlite://memory", 1)
    }

    @Test func configureRuntimeRejectsInvalidDatabaseURL() async throws {
        unsetenv("DISCORD_BOT_TOKEN")
        setenv("DATABASE_URL", "mysql://nope", 1)
        let app = try await Application.make(.testing)
        do {
            do {
                _ = try await configureRuntime(app, defaultDatabaseURL: "sqlite://memory")
                Issue.record("expected invalid DATABASE_URL to throw")
            } catch {
                // Abort / validation failure — any throw is success
            }
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        setenv("DATABASE_URL", "sqlite://memory", 1)
    }

    @Test func memoryRepositoryAppendFactsAndForget() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            try await MemoryRepository.appendFact(
                userId: "u1",
                guildId: "g1",
                fact: "likes tea",
                on: db
            )
            try await MemoryRepository.appendFact(
                userId: "u1",
                guildId: "g1",
                fact: "lives in nyc",
                on: db
            )
            var facts = try await MemoryRepository.facts(userId: "u1", guildId: "g1", on: db)
            #expect(facts == ["likes tea", "lives in nyc"])

            try await MemoryRepository.forgetFact(userId: "u1", guildId: "g1", index: 1, on: db)
            facts = try await MemoryRepository.facts(userId: "u1", guildId: "g1", on: db)
            #expect(facts == ["lives in nyc"])

            do {
                try await MemoryRepository.forgetFact(userId: "u1", guildId: "g1", index: 9, on: db)
                Issue.record("expected invalidIndex")
            } catch let error as MemoryForgetError {
                #expect(error == .invalidIndex)
            }

            do {
                try await MemoryRepository.forgetFact(userId: "nobody", guildId: "g1", index: 1, on: db)
                Issue.record("expected noMemory")
            } catch let error as MemoryForgetError {
                #expect(error == .noMemory)
            }

            try await MemoryRepository.appendFact(userId: "u1", guildId: "g1", fact: "   ", on: db)
            facts = try await MemoryRepository.facts(userId: "u1", guildId: "g1", on: db)
            #expect(facts == ["lives in nyc"])
        }
    }

    @Test func channelRepositoryBumpIncrementsCount() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            #expect(try await ChannelRepository.messageCount(channelId: "c1", guildId: "g1", on: db) == 0)
            try await ChannelRepository.bump(channelId: "c1", guildId: "g1", on: db)
            try await ChannelRepository.bump(channelId: "c1", guildId: "g1", on: db)
            #expect(try await ChannelRepository.messageCount(channelId: "c1", guildId: "g1", on: db) == 2)
            #expect(try await ChannelRepository.summary(channelId: "c1", guildId: "g1", on: db) == "")
        }
    }

    @Test func statusCountsReflectWrites() async throws {
        try await withRuntime { app, _ in
            let db = app.db
            var counts = try await StatusRepository.counts(on: db)
            #expect(counts.users == 0)
            #expect(counts.channels == 0)
            #expect(counts.messages == 0)

            try await MemoryRepository.appendFact(userId: "u1", guildId: "g1", fact: "fact", on: db)
            try await ChannelRepository.bump(channelId: "c1", guildId: "g1", on: db)
            try await MessageRepository.insert(
                discordMessageId: "m1",
                channelId: "c1",
                guildId: "g1",
                authorId: "u1",
                content: "hello",
                on: db
            )

            counts = try await StatusRepository.counts(on: db)
            #expect(counts.users == 1)
            #expect(counts.channels == 1)
            #expect(counts.messages == 1)
        }
    }

    @Test func botRuntimeRememberForgetAndState() async throws {
        try await withRuntime { _, runtime in
            try await runtime.remember(userId: "u1", guildId: "g1", fact: "alpha")
            try await runtime.remember(userId: "u1", guildId: "g1", fact: "beta")

            var state = await runtime.userState(userId: "u1", guildId: "g1")
            #expect(state.facts == ["alpha", "beta"])

            try await runtime.forget(userId: "u1", guildId: "g1", index: 2)
            state = await runtime.userState(userId: "u1", guildId: "g1")
            #expect(state.facts == ["alpha"])

            let channel = await runtime.channelState(channelId: "c1", guildId: "g1")
            #expect(channel.summary == "")

            let metrics = await runtime.metricsSnapshot()
            #expect(metrics.discordBotUserId.isEmpty)
            #expect(metrics.discordState == "disconnected")
        }
    }
}
