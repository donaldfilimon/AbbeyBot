import Fluent
import Foundation
import Vapor

/// Single-row record of the desktop app's last-reported sync outcome, for the operator
/// dashboard's "Sync" tab. There is exactly one installation talking to a given server in
/// the shipped topology, so this is a singleton table rather than keyed per-device.
public final class SyncStatusRecord: Model, Content, @unchecked Sendable {
    public static let schema = "sync_status_records"

    @ID(key: .id)
    public var id: UUID?

    @OptionalField(key: "last_pull_at")
    public var lastPullAt: Date?

    @OptionalField(key: "last_pull_error")
    public var lastPullError: String?

    @OptionalField(key: "last_push_at")
    public var lastPushAt: Date?

    @OptionalField(key: "last_push_error")
    public var lastPushError: String?

    @Field(key: "pending_push_count")
    public var pendingPushCount: Int

    @Timestamp(key: "reported_at", on: .update)
    public var reportedAt: Date?

    public init() {}

    public init(
        id: UUID? = nil,
        lastPullAt: Date? = nil,
        lastPullError: String? = nil,
        lastPushAt: Date? = nil,
        lastPushError: String? = nil,
        pendingPushCount: Int = 0
    ) {
        self.id = id
        self.lastPullAt = lastPullAt
        self.lastPullError = lastPullError
        self.lastPushAt = lastPushAt
        self.lastPushError = lastPushError
        self.pendingPushCount = pendingPushCount
    }
}
