import Foundation
import Observation
#if canImport(Security)
import Security
#endif

public enum OperatingMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case standalone
    case liveDiscord
    public var id: String { rawValue }
}

public enum QuasarBackend: String, CaseIterable, Codable, Identifiable, Sendable {
    case local, remote
    public var id: String { rawValue }
}

public enum InferenceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case deterministicFloor
    case onDevice
    case remoteCompatible
    public var id: String { rawValue }
}

/// Process configuration for AbbeyBot. Token: Keychain on Apple platforms, env/UserDefaults elsewhere.
/// Process env knobs (`ABBEY_INFERENCE_MODE`, `ABBEY_REMOTE_ENDPOINT`, `ABBEY_DRY_RUN`, …) override
/// UserDefaults when set so headless CLI/server boots stay hermetic.
@Observable
public final class AppConfig: @unchecked Sendable {
    public static let shared = AppConfig()

    private let tokens: any TokenStoring

    private let defaults: UserDefaults

    public var operatingMode: OperatingMode {
        didSet { defaults.set(operatingMode.rawValue, forKey: Keys.operatingMode) }
    }
    public var inferenceMode: InferenceMode {
        didSet { defaults.set(inferenceMode.rawValue, forKey: Keys.inferenceMode) }
    }
    public var remoteEndpoint: String {
        didSet { defaults.set(remoteEndpoint, forKey: Keys.remoteEndpoint) }
    }
    /// Quasar settings are independent of sync and captured by the desktop at startup.
    public var quasarBackend: QuasarBackend {
        didSet { defaults.set(quasarBackend.rawValue, forKey: Keys.quasarBackend) }
    }
    public var quasarEndpoint: String {
        didSet { defaults.set(quasarEndpoint, forKey: Keys.quasarEndpoint) }
    }
    public var quasarAPIToken: String {
        didSet { tokens.set(quasarAPIToken, account: Keys.quasarAPIToken) }
    }
    public var remoteModel: String {
        didSet { defaults.set(remoteModel, forKey: Keys.remoteModel) }
    }
    public var remoteAPIToken: String {
        didSet { tokens.set(remoteAPIToken, account: Keys.remoteAPIToken) }
    }
    public var replyCooldownSeconds: Double {
        didSet { defaults.set(replyCooldownSeconds, forKey: Keys.replyCooldownSeconds) }
    }
    public var memoryConsolidationIntervalMinutes: Double {
        didSet { defaults.set(memoryConsolidationIntervalMinutes, forKey: Keys.consolidationInterval) }
    }
    public var reputationDecay: Double {
        didSet { defaults.set(reputationDecay, forKey: Keys.reputationDecay) }
    }
    public var confirmationRequiredForDestructiveActions: Bool {
        didSet { defaults.set(confirmationRequiredForDestructiveActions, forKey: Keys.confirmationRequired) }
    }
    public var equityModuleEnabled: Bool {
        didSet { defaults.set(equityModuleEnabled, forKey: Keys.equityModuleEnabled) }
    }

    public var discordBotToken: String {
        didSet { tokens.set(discordBotToken, account: Keys.discordBotToken) }
    }
    public var discordDevGuildId: String {
        didSet { defaults.set(discordDevGuildId, forKey: Keys.discordDevGuildId) }
    }
    public var autoConnectOnLaunch: Bool {
        didSet { defaults.set(autoConnectOnLaunch, forKey: Keys.autoConnectOnLaunch) }
    }

    public var syncServerURL: String {
        didSet { defaults.set(syncServerURL, forKey: Keys.syncServerURL) }
    }
    public var syncAPIToken: String {
        didSet { tokens.set(syncAPIToken, account: Keys.syncAPIToken) }
    }

    /// When true, Discord gateway connect is skipped (`dry-run: would connect`).
    public var dryRun: Bool {
        didSet { defaults.set(dryRun, forKey: Keys.dryRun) }
    }

    /// Twitch IRC OAuth token (env `TWITCH_OAUTH_TOKEN`); empty disables Twitch.
    public var twitchOAuthToken: String {
        didSet { tokens.set(twitchOAuthToken, account: Keys.twitchOAuthToken) }
    }
    public var twitchBotLogin: String {
        didSet { defaults.set(twitchBotLogin, forKey: Keys.twitchBotLogin) }
    }
    public var twitchChannel: String {
        didSet { defaults.set(twitchChannel, forKey: Keys.twitchChannel) }
    }

    /// Industry prompt overlay (`ABBEY_INDUSTRY_PROFILE`); default `general`.
    public var industryProfile: IndustryProfile {
        didSet { defaults.set(industryProfile.rawValue, forKey: Keys.industryProfile) }
    }

    /// Blockchain/decentralization stub — must stay false (no node in this package).
    public var decentralizationEnabled: Bool {
        didSet { defaults.set(decentralizationEnabled, forKey: Keys.decentralizationEnabled) }
    }

    private enum Keys {
        static let operatingMode = "ABBEY_OPERATING_MODE"
        static let inferenceMode = "ABBEY_INFERENCE_MODE"
        static let remoteEndpoint = "ABBEY_REMOTE_ENDPOINT"
        static let remoteModel = "ABBEY_REMOTE_MODEL"
        static let remoteAPIToken = "ABBEY_REMOTE_API_TOKEN"
        static let quasarBackend = "ABBEY_QUASAR_BACKEND"
        static let quasarEndpoint = "ABBEY_QUASAR_ENDPOINT"
        static let quasarAPIToken = "ABBEY_QUASAR_API_TOKEN"
        static let replyCooldownSeconds = "ABBEY_REPLY_COOLDOWN_SECONDS"
        static let consolidationInterval = "ABBEY_MEMORY_CONSOLIDATION_INTERVAL_MIN"
        static let reputationDecay = "ABBEY_REPUTATION_DECAY"
        static let confirmationRequired = "ABBEY_CONFIRMATION_REQUIRED"
        static let equityModuleEnabled = "ABBEY_EQUITY_MODULE_ENABLED"
        static let discordBotToken = "DISCORD_BOT_TOKEN"
        static let discordDevGuildId = "DISCORD_DEV_GUILD_ID"
        static let autoConnectOnLaunch = "ABBEY_DISCORD_AUTO_CONNECT"
        static let syncServerURL = "ABBEY_SYNC_SERVER_URL"
        static let syncAPIToken = "ABBEY_SYNC_API_TOKEN"
        static let dryRun = "ABBEY_DRY_RUN"
        static let twitchOAuthToken = "TWITCH_OAUTH_TOKEN"
        static let twitchBotLogin = "TWITCH_BOT_LOGIN"
        static let twitchChannel = "TWITCH_CHANNEL"
        static let industryProfile = "ABBEY_INDUSTRY_PROFILE"
        static let decentralizationEnabled = "ABBEY_DECENTRALIZATION_ENABLED"
    }

    /// - Parameter environment: process env; when a key is present it wins over UserDefaults
    ///   for process knobs (`ABBEY_INFERENCE_MODE`, `ABBEY_REMOTE_ENDPOINT`, `ABBEY_DRY_RUN`, …)
    ///   so CLI/server smokes are not blocked by desktop GUI leftovers.
    /// - Parameter tokens: where secrets are read and written. Defaults to the login Keychain;
    ///   tests MUST pass `InMemoryTokenStore()` — see that type for what happens if they do not.
    public init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tokens: any TokenStoring = KeychainTokenStore()
    ) {
        self.tokens = tokens
        self.defaults = defaults
        let modeRaw = defaults.string(forKey: Keys.operatingMode) ?? ""
        if modeRaw == "mirror" {
            self.operatingMode = .liveDiscord
        } else {
            self.operatingMode = OperatingMode(rawValue: modeRaw) ?? .standalone
        }
        // Env wins (same as dryRun): hermetic CLI/server must override desktop UserDefaults.
        if let envInference = environment["ABBEY_INFERENCE_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envInference.isEmpty,
           let parsed = InferenceMode(rawValue: envInference)
        {
            self.inferenceMode = parsed
        } else {
            let inferenceModeRaw = defaults.string(forKey: Keys.inferenceMode) ?? ""
            self.inferenceMode = InferenceMode(rawValue: inferenceModeRaw) ?? .deterministicFloor
        }
        if let envEndpoint = environment["ABBEY_REMOTE_ENDPOINT"] {
            self.remoteEndpoint = envEndpoint
        } else {
            self.remoteEndpoint = defaults.string(forKey: Keys.remoteEndpoint) ?? ""
        }
        self.quasarBackend = QuasarBackend(rawValue: environment[Keys.quasarBackend]
            ?? defaults.string(forKey: Keys.quasarBackend) ?? "local") ?? .local
        self.quasarEndpoint = environment[Keys.quasarEndpoint] ?? defaults.string(forKey: Keys.quasarEndpoint) ?? "https://api.xfoss.dev"
        self.quasarAPIToken = environment[Keys.quasarAPIToken] ?? tokens.get(account: Keys.quasarAPIToken) ?? ""
        self.remoteModel = environment[Keys.remoteModel] ?? defaults.string(forKey: Keys.remoteModel) ?? "abbey-remote"
        self.remoteAPIToken = environment[Keys.remoteAPIToken] ?? tokens.get(account: Keys.remoteAPIToken) ?? ""
        let cooldown = defaults.double(forKey: Keys.replyCooldownSeconds)
        self.replyCooldownSeconds = cooldown > 0 ? cooldown : 8.0
        let interval = defaults.double(forKey: Keys.consolidationInterval)
        self.memoryConsolidationIntervalMinutes = interval > 0 ? interval : 15.0
        let decay = defaults.double(forKey: Keys.reputationDecay)
        self.reputationDecay = decay > 0 ? decay : 0.95
        self.confirmationRequiredForDestructiveActions = defaults.object(forKey: Keys.confirmationRequired) as? Bool ?? true
        self.equityModuleEnabled = defaults.object(forKey: Keys.equityModuleEnabled) as? Bool ?? true
        self.discordBotToken = tokens.get(account: Keys.discordBotToken)
            ?? environment["DISCORD_BOT_TOKEN"]
            ?? ""
        self.discordDevGuildId = defaults.string(forKey: Keys.discordDevGuildId)
            ?? environment["DISCORD_DEV_GUILD_ID"]
            ?? ""
        self.autoConnectOnLaunch = defaults.object(forKey: Keys.autoConnectOnLaunch) as? Bool ?? false
        self.syncServerURL = defaults.string(forKey: Keys.syncServerURL)
            ?? environment["ABBEY_SYNC_SERVER_URL"]
            ?? ""
        self.syncAPIToken = tokens.get(account: Keys.syncAPIToken)
            ?? environment["ABBEY_SYNC_API_TOKEN"]
            ?? ""
        if let envDry = environment["ABBEY_DRY_RUN"] {
            let normalized = envDry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.dryRun = ["1", "true", "yes", "on"].contains(normalized)
        } else if let stored = defaults.object(forKey: Keys.dryRun) as? Bool {
            self.dryRun = stored
        } else {
            self.dryRun = false
        }
        self.twitchOAuthToken = tokens.get(account: Keys.twitchOAuthToken)
            ?? environment["TWITCH_OAUTH_TOKEN"]
            ?? ""
        self.twitchBotLogin = defaults.string(forKey: Keys.twitchBotLogin)
            ?? environment["TWITCH_BOT_LOGIN"]
            ?? ""
        self.twitchChannel = defaults.string(forKey: Keys.twitchChannel)
            ?? environment["TWITCH_CHANNEL"]
            ?? ""
        let industryRaw = defaults.string(forKey: Keys.industryProfile)
            ?? environment["ABBEY_INDUSTRY_PROFILE"]
        self.industryProfile = IndustryProfile.resolve(industryRaw)
        if let envDec = environment["ABBEY_DECENTRALIZATION_ENABLED"] {
            let normalized = envDec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.decentralizationEnabled = ["1", "true", "yes", "on"].contains(normalized)
        } else if let stored = defaults.object(forKey: Keys.decentralizationEnabled) as? Bool {
            self.decentralizationEnabled = stored
        } else {
            self.decentralizationEnabled = false
        }
    }
}

/// Where AppConfig's secrets live. Injectable because the alternative is a static that writes
/// to whoever runs the process — see `InMemoryTokenStore`.
public protocol TokenStoring: Sendable {
    func get(account: String) -> String?
    func set(_ value: String, account: String)
}

/// Production store: the login Keychain (env/UserDefaults off-Apple).
public struct KeychainTokenStore: TokenStoring {
    public init() {}
    public func get(account: String) -> String? { TokenStore.get(account: account) }
    public func set(_ value: String, account: String) { TokenStore.set(value, account: account) }
}

/// Test store. Not a convenience: `AppConfig`'s token `didSet` hooks write through on every
/// assignment, so a test that mutates `discordBotToken` against the default store edits the
/// *developer's* login Keychain. That is not hypothetical — `AbbeyCoreTests` assigning `""`
/// deleted the real `DISCORD_BOT_TOKEN` item on every run, and one assigning a literal left
/// `token` in its place (item created 2026-09-09 00:01 EDT, deleted by hand). An empty token
/// under `liveDiscord` is exactly the startup state that used to SIGTRAP the app.
public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ initial: [String: String] = [:]) { self.values = initial }

    public func get(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    public func set(_ value: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        if value.isEmpty { values.removeValue(forKey: account) } else { values[account] = value }
    }
}

enum TokenStore {
    private static let service = "com.donaldfilimon.AbbeyBot"

    static func get(account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return UserDefaults.standard.string(forKey: "\(service).\(account)")
        #endif
    }

    static func set(_ value: String, account: String) {
        #if canImport(Security)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
        #else
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: "\(service).\(account)")
        } else {
            UserDefaults.standard.set(value, forKey: "\(service).\(account)")
        }
        #endif
    }
}
