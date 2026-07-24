import Foundation
import SwiftData

/// Mirrors `UserMemory` from the Vapor/Fluent bot. Per-user, per-guild fact store plus
/// the SocialBrain reputation score (0.0–1.0).
@Model
public final class UserMemory {
    @Attribute(.unique) public var compositeKey: String
    public var discordUserId: String
    public var guildId: String
    public var facts: [String]
    public var reputation: Double
    public var interactionCount: Int
    public var updatedAt: Date

    public init(discordUserId: String, guildId: String, facts: [String] = [], reputation: Double = 0.5, interactionCount: Int = 0, updatedAt: Date = .now) {
        self.compositeKey = "\(guildId):\(discordUserId)"
        self.discordUserId = discordUserId
        self.guildId = guildId
        self.facts = facts
        self.reputation = reputation
        self.interactionCount = interactionCount
        self.updatedAt = updatedAt
    }
}
