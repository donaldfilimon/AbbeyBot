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

/// Where startup validation runs — desktop UserDefaults must not block headless HTTP/CLI boots.
public enum AppConfigValidationScope: Sendable {
    /// Desktop GUI: enforce `liveDiscord` token (unless dry-run) and full checks.
    case desktop
    /// AbbeyServer / `abbey` CLI: skip desktop `operatingMode` token gate; still validate numerics,
    /// remote endpoint when `remoteCompatible`, and sync URL shape when set.
    case headless
}

extension AppConfig {
    /// Fail-loud checks before Discord connect / serve.
    /// - Parameter scope: `.desktop` (default) vs `.headless` for server/CLI.
    public func validateForStartup(scope: AppConfigValidationScope = .desktop) throws {
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
            do {
                try SyncTransportPolicy.validate(baseURL: sync)
            } catch {
                throw AppConfigValidationError.syncServerURLInvalid(sync)
            }
        }

        // Desktop-only: UserDefaults may keep liveDiscord from a prior GUI session.
        // Headless processes previously booted HTTP-only without a token — keep that.
        if scope == .desktop, operatingMode == .liveDiscord, !dryRun {
            let token = discordBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                throw AppConfigValidationError.liveDiscordMissingToken
            }
        }

        try DecentralizationPolicy(enabled: decentralizationEnabled).validate()
    }

    /// Whether launch may open a live Discord gateway connection.
    ///
    /// This is the guard that replaced `AbbeyBotApp.init`'s `fatalError` on a
    /// `liveDiscord`-without-token config: the app now boots, shows the startup banner, and
    /// simply does not connect. `dryRun` short-circuits the token requirement because a dry
    /// run never reaches the network (`dry-run: would connect`), so an empty token is fine
    /// there. The token is trimmed for the same reason `validateForStartup` trims it — a
    /// whitespace-only token is not a token.
    public var shouldAutoConnectDiscord: Bool {
        guard operatingMode == .liveDiscord, autoConnectOnLaunch else { return false }
        return dryRun || !discordBotToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
