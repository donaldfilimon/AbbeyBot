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

public enum InferenceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case deterministicFloor
    case onDevice
    case remoteCompatible
    public var id: String { rawValue }
}

/// Process configuration for AbbeyBot. Token: Keychain on Apple platforms, env/UserDefaults elsewhere.
@Observable
public final class AppConfig: @unchecked Sendable {
    public static let shared = AppConfig()

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
        didSet { TokenStore.set(discordBotToken, account: Keys.discordBotToken) }
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
        didSet { TokenStore.set(syncAPIToken, account: Keys.syncAPIToken) }
    }

    /// When true, Discord gateway connect is skipped (`dry-run: would connect`).
    public var dryRun: Bool {
        didSet { defaults.set(dryRun, forKey: Keys.dryRun) }
    }

    private enum Keys {
        static let operatingMode = "ABBEY_OPERATING_MODE"
        static let inferenceMode = "ABBEY_INFERENCE_MODE"
        static let remoteEndpoint = "ABBEY_REMOTE_ENDPOINT"
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
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let modeRaw = defaults.string(forKey: Keys.operatingMode) ?? ""
        if modeRaw == "mirror" {
            self.operatingMode = .liveDiscord
        } else {
            self.operatingMode = OperatingMode(rawValue: modeRaw) ?? .standalone
        }
        let inferenceModeRaw = defaults.string(forKey: Keys.inferenceMode)
            ?? ProcessInfo.processInfo.environment["ABBEY_INFERENCE_MODE"]
            ?? ""
        self.inferenceMode = InferenceMode(rawValue: inferenceModeRaw) ?? .deterministicFloor
        self.remoteEndpoint = defaults.string(forKey: Keys.remoteEndpoint)
            ?? ProcessInfo.processInfo.environment["ABBEY_REMOTE_ENDPOINT"]
            ?? ""
        let cooldown = defaults.double(forKey: Keys.replyCooldownSeconds)
        self.replyCooldownSeconds = cooldown > 0 ? cooldown : 8.0
        let interval = defaults.double(forKey: Keys.consolidationInterval)
        self.memoryConsolidationIntervalMinutes = interval > 0 ? interval : 15.0
        let decay = defaults.double(forKey: Keys.reputationDecay)
        self.reputationDecay = decay > 0 ? decay : 0.95
        self.confirmationRequiredForDestructiveActions = defaults.object(forKey: Keys.confirmationRequired) as? Bool ?? true
        self.equityModuleEnabled = defaults.object(forKey: Keys.equityModuleEnabled) as? Bool ?? true
        self.discordBotToken = TokenStore.get(account: Keys.discordBotToken)
            ?? ProcessInfo.processInfo.environment["DISCORD_BOT_TOKEN"]
            ?? ""
        self.discordDevGuildId = defaults.string(forKey: Keys.discordDevGuildId)
            ?? ProcessInfo.processInfo.environment["DISCORD_DEV_GUILD_ID"]
            ?? ""
        self.autoConnectOnLaunch = defaults.object(forKey: Keys.autoConnectOnLaunch) as? Bool ?? false
        self.syncServerURL = defaults.string(forKey: Keys.syncServerURL)
            ?? ProcessInfo.processInfo.environment["ABBEY_SYNC_SERVER_URL"]
            ?? ""
        self.syncAPIToken = TokenStore.get(account: Keys.syncAPIToken)
            ?? ProcessInfo.processInfo.environment["ABBEY_SYNC_API_TOKEN"]
            ?? ""
        if let envDry = ProcessInfo.processInfo.environment["ABBEY_DRY_RUN"] {
            let normalized = envDry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.dryRun = ["1", "true", "yes", "on"].contains(normalized)
        } else if let stored = defaults.object(forKey: Keys.dryRun) as? Bool {
            self.dryRun = stored
        } else {
            self.dryRun = false
        }
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
