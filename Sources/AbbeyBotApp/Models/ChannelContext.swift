import Foundation
import SwiftData

/// Mirrors `ChannelContext` from the Vapor/Fluent bot — a rolling, compressed summary
/// of recent channel activity, recomputed on the cadence set by
/// `AppConfig.memoryConsolidationIntervalMinutes` (ABBEY_MEMORY_CONSOLIDATION_INTERVAL_MIN).
@Model
public final class ChannelContext {
    /// Unique across guilds — channel IDs like `"general"` collide otherwise.
    @Attribute(.unique) public var compositeKey: String
    public var channelId: String
    public var guildId: String
    public var summary: String
    public var messageCount: Int
    public var updatedAt: Date

    public init(channelId: String, guildId: String, summary: String = "", messageCount: Int = 0, updatedAt: Date = .now) {
        self.compositeKey = "\(guildId):\(channelId)"
        self.channelId = channelId
        self.guildId = guildId
        self.summary = summary
        self.messageCount = messageCount
        self.updatedAt = updatedAt
    }
}
