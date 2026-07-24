import Foundation

/// Pure reputation EMA / penalty math shared by SwiftData and Fluent SocialBrain adapters.
public enum ReputationMath: Sendable {
    public static let defaultScore: Double = 0.5
    public static let penaltyDelta: Double = 0.1

    public static func compositeKey(guildId: String, id: String) -> String {
        "\(guildId):\(id)"
    }

    public static func cacheKey(userId: String, guildId: String) -> String {
        compositeKey(guildId: guildId, id: userId)
    }

    public static func channelKey(channelId: String, guildId: String) -> String {
        compositeKey(guildId: guildId, id: channelId)
    }

    /// Exponential moving average: `current * alpha + quality * (1 - alpha)`.
    public static func blend(current: Double, quality: Double, decay alpha: Double) -> Double {
        current * alpha + quality * (1 - alpha)
    }

    public static func penalize(current: Double) -> Double {
        max(0, current - penaltyDelta)
    }
}
