import Foundation

/// Canonical persona name resolution for ingest + slash commands.
public enum PersonaName: Sendable {
    public static func resolve(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Word-boundary aware so "average" / "capability" do not hijack Aviva / Abi.
        if lower == "av" || lower.range(of: #"\baviva\b"#, options: .regularExpression) != nil {
            return "Aviva"
        }
        if lower.range(of: #"\babi\b"#, options: .regularExpression) != nil {
            return "Abi"
        }
        return "Abbey"
    }
}
