import Foundation

/// Outcome of a gateway voice-state update (presence only — no Opus/UDP).
public enum VoiceUpdateResult: Sendable, Equatable {
    case requested
    case gatewayUnavailable
    case invalidIdentifiers
}

/// Shared desktop / server path for `/voice` and UI join/leave.
///
/// Engines supply connection state plus thin bridge closures so this lives in
/// AbbeyCore without depending on SwiftData or Vapor.
public enum VoicePresence: Sendable {
    public static func perform(
        _ action: VoiceAction,
        guildId: String,
        isConnected: Bool,
        gatewayReady: Bool,
        join: @Sendable (_ guildId: String, _ channelId: String) async -> VoiceUpdateResult,
        leave: @Sendable (_ guildId: String) async -> VoiceUpdateResult
    ) async -> String {
        guard isConnected else { return DiscordCopy.voiceNotConnected }
        // Dry-run sets state=.connected without a gateway — fail clearly before join/leave.
        guard gatewayReady else { return DiscordCopy.voiceDryRunNoGateway }

        let trimmedGuild = guildId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuild.isEmpty, trimmedGuild != "DM" else {
            return DiscordCopy.voiceMissingGuild
        }

        switch action {
        case .join(let channelId):
            let trimmedChannel = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedChannel.isEmpty else { return DiscordCopy.voiceMissingChannel }
            switch await join(trimmedGuild, trimmedChannel) {
            case .requested:
                return DiscordCopy.voiceJoined(channelId: trimmedChannel)
            case .gatewayUnavailable:
                return DiscordCopy.voiceNotConnected
            case .invalidIdentifiers:
                return DiscordCopy.voiceMissingChannel
            }
        case .leave:
            switch await leave(trimmedGuild) {
            case .requested:
                return DiscordCopy.voiceLeft(guildId: trimmedGuild)
            case .gatewayUnavailable:
                return DiscordCopy.voiceLeaveFailed
            case .invalidIdentifiers:
                return DiscordCopy.voiceMissingGuild
            }
        }
    }
}
