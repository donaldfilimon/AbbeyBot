import Fluent

/// Soft-delete columns for append-only / equity sync entities.
///
/// Idempotent like `AddDeletedAtToUserAndChannel` so greenfield `CreateAll` (which already
/// declares `deleted_at`) and existing databases both succeed.
public struct AddDeletedAtToAppendOnlyEntities: AsyncMigration {
    public init() {}

    public func prepare(on database: Database) async throws {
        for schema in [
            GuildMessage.schema,
            ReputationEvent.schema,
            InteractionLog.schema,
            EquityIdea.schema
        ] {
            try await addDeletedAtIfNeeded(to: schema, on: database)
        }
    }

    public func revert(on database: Database) async throws {
        for schema in [
            GuildMessage.schema,
            ReputationEvent.schema,
            InteractionLog.schema,
            EquityIdea.schema
        ] {
            try await database.schema(schema).deleteField("deleted_at").update()
        }
    }

    private func addDeletedAtIfNeeded(to schema: String, on database: Database) async throws {
        do {
            try await database.schema(schema).field("deleted_at", .datetime).update()
        } catch {
            let message = String(describing: error).lowercased()
            if message.contains("duplicate column") { return }
            throw error
        }
    }
}
