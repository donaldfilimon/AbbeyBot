import Fluent

/// Preserves authoritative server timestamps beside Fluent's automatic local timestamps.
/// This is required by CLI pull conflict resolution: apply time must never masquerade as
/// source time and reject a legitimate later server update.
public struct AddSyncSourceTimestamps: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(UserMemory.schema)
            .field("source_updated_at", .datetime)
            .update()
        try await database.schema(ChannelContext.schema)
            .field("source_updated_at", .datetime)
            .update()
        try await database.schema(GuildMessage.schema)
            .field("source_created_at", .datetime)
            .update()
        try await database.schema(ReputationEvent.schema)
            .field("source_created_at", .datetime)
            .update()
        try await database.schema(InteractionLog.schema)
            .field("source_created_at", .datetime)
            .update()
        try await database.schema(EquityIdea.schema)
            .field("source_generated_at", .datetime)
            .update()
    }

    public func revert(on database: any Database) async throws {
        try await database.schema(EquityIdea.schema)
            .deleteField("source_generated_at")
            .update()
        try await database.schema(InteractionLog.schema)
            .deleteField("source_created_at")
            .update()
        try await database.schema(ReputationEvent.schema)
            .deleteField("source_created_at")
            .update()
        try await database.schema(GuildMessage.schema)
            .deleteField("source_created_at")
            .update()
        try await database.schema(ChannelContext.schema)
            .deleteField("source_updated_at")
            .update()
        try await database.schema(UserMemory.schema)
            .deleteField("source_updated_at")
            .update()
    }
}
