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
public struct SyncPullCursorSet: Codable, Equatable, Sendable {
    public var users: SyncPullCursor?
    public var channels: SyncPullCursor?
    public var messages: SyncPullCursor?
    public var reputation: SyncPullCursor?
    public var interactions: SyncPullCursor?
    public var equity: SyncPullCursor?

    public init(
        users: SyncPullCursor? = nil,
        channels: SyncPullCursor? = nil,
        messages: SyncPullCursor? = nil,
        reputation: SyncPullCursor? = nil,
        interactions: SyncPullCursor? = nil,
        equity: SyncPullCursor? = nil
    ) {
        self.users = users
        self.channels = channels
        self.messages = messages
        self.reputation = reputation
        self.interactions = interactions
        self.equity = equity
    }

    public init(legacyTimestamp: Date) {
        let cursor = SyncPullCursor(changedAt: legacyTimestamp)
        self.init(
            users: cursor,
            channels: cursor,
            messages: cursor,
            reputation: cursor,
            interactions: cursor,
            equity: cursor
        )
    }

    public subscript(entity: SyncPullEntity) -> SyncPullCursor? {
        get {
            switch entity {
            case .users: users
            case .channels: channels
            case .messages: messages
            case .reputation: reputation
            case .interactions: interactions
            case .equity: equity
            }
        }
        set {
            switch entity {
            case .users: users = newValue
            case .channels: channels = newValue
            case .messages: messages = newValue
            case .reputation: reputation = newValue
            case .interactions: interactions = newValue
            case .equity: equity = newValue
            }
        }
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
