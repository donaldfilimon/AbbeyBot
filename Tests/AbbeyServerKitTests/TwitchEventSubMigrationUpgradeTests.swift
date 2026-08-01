import AbbeyServerKit
import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@Suite("Twitch EventSub migration upgrade matrix", .serialized)
struct TwitchEventSubMigrationUpgradeTests {
    @Test func freshBootstrapCreatesTableAndUniqueConstraint() async throws {
        try await withMigrationDatabase { app in
            app.migrations.add(CreateAll())
            app.migrations.add(AddTwitchEventSubDeliveries())
            try await app.autoMigrate()

            try await assertReplayTableAndUniqueConstraint(on: app.db, messageId: "fresh")
            #expect(try await migrationCount(AddTwitchEventSubDeliveries().name, on: app.db) == 1)
        }
    }

    @Test func loggedCreateAllWithoutTableReceivesForwardMigration() async throws {
        try await withMigrationDatabase { app in
            try await recordCreateAllAsAlreadyApplied(on: app.db)
            app.migrations.add(AddTwitchEventSubDeliveries())
            try await app.autoMigrate()

            try await assertReplayTableAndUniqueConstraint(on: app.db, messageId: "old-absent")
            #expect(try await migrationCount(AddTwitchEventSubDeliveries().name, on: app.db) == 1)
        }
    }

    @Test func loggedCreateAllWithExistingTableIsAdoptedAndPrepareIsRepeatable() async throws {
        try await withMigrationDatabase { app in
            try await recordCreateAllAsAlreadyApplied(on: app.db)
            try await createLegacyReplayTable(on: app.db)
            app.migrations.add(AddTwitchEventSubDeliveries())
            try await app.autoMigrate()

            // A direct second prepare pins the `CREATE TABLE IF NOT EXISTS` behavior as well as
            // Fluent's migration-log skip on subsequent application boots.
            try await AddTwitchEventSubDeliveries().prepare(on: app.db)
            try await assertReplayTableAndUniqueConstraint(on: app.db, messageId: "old-present")
            #expect(try await migrationCount(AddTwitchEventSubDeliveries().name, on: app.db) == 1)
        }
    }

    @Test func revertingCompatibilityMigrationPreservesCreateAllOwnedTable() async throws {
        try await withMigrationDatabase { app in
            try await recordCreateAllAsAlreadyApplied(on: app.db)
            try await createLegacyReplayTable(on: app.db)
            app.migrations.add(AddTwitchEventSubDeliveries())
            try await app.autoMigrate()

            try await app.migrator.revertLastBatch().get()

            #expect(try await migrationCount(AddTwitchEventSubDeliveries().name, on: app.db) == 0)
            #expect(try await migrationCount(CreateAll().name, on: app.db) == 1)
            try await assertReplayTableAndUniqueConstraint(on: app.db, messageId: "after-revert")
        }
    }
}

private func withMigrationDatabase(
    _ body: @Sendable (Application) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)
    let databaseID = DatabaseID(string: "twitch-migration-\(UUID().uuidString)")
    app.databases.use(.sqlite(.memory), as: databaseID)
    app.databases.default(to: databaseID)
    do {
        try await body(app)
        try await app.asyncShutdown()
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

private func recordCreateAllAsAlreadyApplied(on database: any Database) async throws {
    try await MigrationLog.migration.prepare(on: database).get()
    try await MigrationLog(name: CreateAll().name, batch: 1).create(on: database)
}

private func createLegacyReplayTable(on database: any Database) async throws {
    try await database.schema(TwitchEventSubDelivery.schema)
        .id()
        .field("message_id", .string, .required)
        .field("claimed_at", .datetime, .required)
        .unique(on: "message_id")
        .create()
}

private func migrationCount(_ name: String, on database: any Database) async throws -> Int {
    try await MigrationLog.query(on: database)
        .filter(\.$name == name)
        .count()
}

private func assertReplayTableAndUniqueConstraint(
    on database: any Database,
    messageId: String
) async throws {
    try await TwitchEventSubDelivery(messageId: messageId, claimedAt: Date()).create(on: database)
    await #expect(throws: (any Error).self) {
        try await TwitchEventSubDelivery(messageId: messageId, claimedAt: Date()).create(on: database)
    }
    #expect(
        try await TwitchEventSubDelivery.query(on: database)
            .filter(\.$messageId == messageId)
            .count() == 1
    )
}
