import Fluent

/// Durable Twitch EventSub dedupe. The unique constraint on `message_id` is what makes
/// `TwitchEventSubReplayGuard.claim` atomic — the insert either wins or violates.
///
/// This forward migration intentionally coexists with the table in `CreateAll`. Fluent tracks
/// applied migrations by type name, so a database that ran an older `CreateAll` without this
/// table needs a separately named migration to receive it. Fresh databases still use
/// `CreateAll` as the whole-schema owner so its revert remains complete.
///
/// `ignoreExisting()` covers the opposite population. This table shipped *inside* `CreateAll`
/// on `origin/main` (04c0250), so a database migrated from that commit already has the table
/// while this migration is unrecorded — a plain `create()` emits `CREATE TABLE` with no
/// `IF NOT EXISTS` (Fluent's `exclusiveCreate` defaults to true) and `autoMigrate` would abort
/// boot with "table already exists". Adopting the existing table is safe because the pre-split
/// definition is identical to this one, field for field and constraint for constraint. Fluent's
/// own `MigrationLog` migration uses `ignoreExisting()` for the same reason.
public struct AddTwitchEventSubDeliveries: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(TwitchEventSubDelivery.schema)
            .id()
            .field("message_id", .string, .required)
            .field("claimed_at", .datetime, .required)
            .unique(on: "message_id")
            .ignoreExisting()
            .create()
    }

    public func revert(on database: any Database) async throws {
        // Deliberately do not drop the table. Some deployed databases received it from
        // `CreateAll` before this migration name existed. Once the forward migration adopts
        // that table there is no portable way to distinguish prior ownership, and dropping it
        // would corrupt rollback on those databases. `CreateAll.revert` remains responsible for
        // whole-schema removal; reverting only this compatibility migration is metadata-only.
    }
}
