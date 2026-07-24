import Foundation

public enum AppConfigValidationError: Error, LocalizedError, Sendable {
    case liveDiscordMissingToken
    case remoteEndpointMissing
    case remoteEndpointInvalid(String)
    case syncServerURLInvalid(String)
    case replyCooldownNegative
    case consolidationIntervalNonPositive
    case reputationDecayOutOfRange(Double)

    public var errorDescription: String? {
        switch self {
        case .liveDiscordMissingToken:
            return "operatingMode=liveDiscord requires a non-empty DISCORD_BOT_TOKEN (or Keychain token)"
        case .remoteEndpointMissing:
            return "inferenceMode=remoteCompatible requires ABBEY_REMOTE_ENDPOINT"
        case .remoteEndpointInvalid(let value):
            return "ABBEY_REMOTE_ENDPOINT is not a valid URL: \(value)"
        case .syncServerURLInvalid(let value):
            return "ABBEY_SYNC_SERVER_URL is not a valid URL: \(value)"
        case .replyCooldownNegative:
            return "ABBEY_REPLY_COOLDOWN_SECONDS must be ≥ 0"
        case .consolidationIntervalNonPositive:
            return "ABBEY_MEMORY_CONSOLIDATION_INTERVAL_MIN must be > 0"
        case .reputationDecayOutOfRange(let value):
            return "ABBEY_REPUTATION_DECAY must be in (0, 1]; got \(value)"
        }
    }
}

extension AppConfig {
    /// Fail-loud checks before Discord connect / serve. Dry-run skips the liveDiscord token requirement.
    public func validateForStartup() throws {
        if replyCooldownSeconds < 0 {
            throw AppConfigValidationError.replyCooldownNegative
        }
        if memoryConsolidationIntervalMinutes <= 0 {
            throw AppConfigValidationError.consolidationIntervalNonPositive
        }
        if reputationDecay <= 0 || reputationDecay > 1 {
            throw AppConfigValidationError.reputationDecayOutOfRange(reputationDecay)
        }

        if inferenceMode == .remoteCompatible {
            let endpoint = remoteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !endpoint.isEmpty else { throw AppConfigValidationError.remoteEndpointMissing }
            guard let url = URL(string: endpoint), url.scheme != nil, url.host != nil else {
                throw AppConfigValidationError.remoteEndpointInvalid(endpoint)
            }
        }

        let sync = syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sync.isEmpty {
            guard let url = URL(string: sync), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
                throw AppConfigValidationError.syncServerURLInvalid(sync)
            }
        }

        if operatingMode == .liveDiscord, !dryRun {
            let token = discordBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                throw AppConfigValidationError.liveDiscordMissingToken
            }
        }
    }
}
