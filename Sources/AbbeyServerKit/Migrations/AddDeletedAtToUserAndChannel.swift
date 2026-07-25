import Fluent

/// Adds soft-delete tombstones for the LWW sync entities (users + channels).
///
/// Kept separate from `CreateAll` so databases that already ran an older `CreateAll`
/// pick up the columns on next boot. Fresh installs also declare `deleted_at` inside
/// `CreateAll`; this migration is therefore **idempotent** (ignores duplicate-column)
/// so parallel `sqlite://memory` tests and greenfield boots both succeed.
public struct AddDeletedAtToUserAndChannel: AsyncMigration {
    public init() {}

    public func prepare(on database: Database) async throws {
        try await addDeletedAtIfNeeded(to: UserMemory.schema, on: database)
        try await addDeletedAtIfNeeded(to: ChannelContext.schema, on: database)
    }

    public func revert(on database: Database) async throws {
        try await database.schema(UserMemory.schema)
            .deleteField("deleted_at")
            .update()
        try await database.schema(ChannelContext.schema)
            .deleteField("deleted_at")
            .update()
    }

    private func addDeletedAtIfNeeded(to schema: String, on database: Database) async throws {
        do {
            try await database.schema(schema)
                .field("deleted_at", .datetime)
                .update()
        } catch {
            let message = String(describing: error).lowercased()
            if message.contains("duplicate column") { return }
            throw error
        }
    }
}
