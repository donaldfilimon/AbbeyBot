import Fluent
import Foundation

/// Durable claim for one Twitch EventSub message ID.
///
/// The database migration owns the unique constraint on `message_id`; inserting this model
/// is therefore the replay guard's atomic compare-and-set operation across processes.
public final class TwitchEventSubDelivery: Model, @unchecked Sendable {
    public static let schema = "twitch_eventsub_deliveries"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "message_id")
    public var messageId: String

    @Field(key: "claimed_at")
    public var claimedAt: Date

    public init() {}

    public init(id: UUID? = nil, messageId: String, claimedAt: Date) {
        self.id = id
        self.messageId = messageId
        self.claimedAt = claimedAt
    }
}
