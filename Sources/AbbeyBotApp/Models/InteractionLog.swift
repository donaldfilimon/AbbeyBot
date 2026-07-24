import Foundation
import SwiftData

/// Mirrors `InteractionLog` — slash command usage analytics. Populated in `.mirror`
/// mode from bot-reported events; populated directly in `.standalone` mode when the
/// user drives commands from within this app's UI.
@Model
public final class InteractionLog {
    public var commandName: String
    public var userId: String
    public var guildId: String
    public var succeeded: Bool
    public var latencyMs: Double
    public var createdAt: Date

    public init(commandName: String, userId: String, guildId: String, succeeded: Bool, latencyMs: Double, createdAt: Date = .now) {
        self.commandName = commandName
        self.userId = userId
        self.guildId = guildId
        self.succeeded = succeeded
        self.latencyMs = latencyMs
        self.createdAt = createdAt
    }
}
