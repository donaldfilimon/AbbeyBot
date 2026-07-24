import Foundation
import SwiftData

/// Mirrors `ReputationEvent` — an audit trail row for every reputation delta SocialBrain
/// applies, so the Users view can show "why" a score moved, not just the current value.
@Model
public final class ReputationEvent {
    public var userId: String
    public var guildId: String
    public var delta: Double
    public var reason: String
    public var createdAt: Date

    public init(userId: String, guildId: String, delta: Double, reason: String, createdAt: Date = .now) {
        self.userId = userId
        self.guildId = guildId
        self.delta = delta
        self.reason = reason
        self.createdAt = createdAt
    }
}
