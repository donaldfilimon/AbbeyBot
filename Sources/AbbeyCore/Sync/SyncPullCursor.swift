import Foundation

/// Stable pagination cursor for one sync entity stream.
///
/// `changedAt` orders changes and `stableID` breaks ties when more than one row has the
/// exact same timestamp. A nil stable ID is the legacy timestamp-only boundary and keeps
/// the historical strict `timestamp > since` behavior during migration.
public struct SyncPullCursor: Codable, Equatable, Sendable {
    public static let initial = SyncPullCursor(changedAt: Date(timeIntervalSince1970: 0))

    public var changedAt: Date
    public var stableID: String?

    public init(changedAt: Date, stableID: String? = nil) {
        self.changedAt = changedAt
        self.stableID = stableID?.isEmpty == true ? nil : stableID
    }
}

public enum SyncPullEntity: String, CaseIterable, Codable, Sendable {
    case users
    case channels
    case messages
    case reputation
    case interactions
    case equity
}

/// Independently advancing cursors prevent one saturated entity stream from forcing all
/// other endpoints to refetch the same rows.
///
/// Backed by one dictionary rather than six optional fields so a seventh entity is one
/// `SyncPullEntity` case, not five separate edits. `SyncPullEntity`'s `String` raw values match
/// the wire/file keys the six-field struct used to synthesize, so existing persisted cursor
/// files (`SyncCursorFileStore`, `SyncCursorStore`) decode unchanged.
public struct SyncPullCursorSet: Codable, Equatable, Sendable {
    private var values: [SyncPullEntity: SyncPullCursor]

    public init(
        users: SyncPullCursor? = nil,
        channels: SyncPullCursor? = nil,
        messages: SyncPullCursor? = nil,
        reputation: SyncPullCursor? = nil,
        interactions: SyncPullCursor? = nil,
        equity: SyncPullCursor? = nil
    ) {
        var values: [SyncPullEntity: SyncPullCursor] = [:]
        values[.users] = users
        values[.channels] = channels
        values[.messages] = messages
        values[.reputation] = reputation
        values[.interactions] = interactions
        values[.equity] = equity
        self.values = values
    }

    public init(legacyTimestamp: Date) {
        let cursor = SyncPullCursor(changedAt: legacyTimestamp)
        self.values = Dictionary(uniqueKeysWithValues: SyncPullEntity.allCases.map { ($0, cursor) })
    }

    public subscript(entity: SyncPullEntity) -> SyncPullCursor? {
        get { values[entity] }
        set { values[entity] = newValue }
    }

    public var earliestChangedAt: Date? {
        SyncPullEntity.allCases.compactMap { self[$0]?.changedAt }.min()
    }
}

/// Decoded rows plus the server's exact, full-precision boundary for the last row.
public struct SyncPullPage<Row: Sendable>: Sendable {
    public var rows: [Row]
    public var serverBoundary: SyncPullCursor?
    public var serverHighWatermark: Date?

    public init(rows: [Row], serverBoundary: SyncPullCursor?, serverHighWatermark: Date? = nil) {
        self.rows = rows
        self.serverBoundary = serverBoundary
        self.serverHighWatermark = serverHighWatermark
    }
}

public enum SyncPullCursorWire {
    public static let timeHeader = "X-Abbey-Sync-Cursor-Time"
    public static let idHeader = "X-Abbey-Sync-Cursor-ID"
    public static let highWatermarkHeader = "X-Abbey-Sync-High-Watermark"
    public static let timeQuery = "since"
    public static let idQuery = "after"
}
