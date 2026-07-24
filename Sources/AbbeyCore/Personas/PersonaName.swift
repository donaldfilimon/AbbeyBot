import Foundation

/// Canonical persona name resolution for ingest + slash commands.
public enum PersonaName: Sendable {
    public static func resolve(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("av") || lower.contains("aviva") { return "Aviva" }
        if lower.hasPrefix("abi") || lower.contains("abi") { return "Abi" }
        return "Abbey"
    }
}
