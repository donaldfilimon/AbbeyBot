import Foundation

/// Formats interaction-log command names for desktop + SPA operator UI.
///
/// - Slash commands (`remember`, `ask`) → `/remember`
/// - Persona prompts (`persona.abbey`) → unchanged (no leading `/`)
/// - Internal / camelCase names (`ingestMessage`) → unchanged (no leading `/`)
public enum InteractionCommandLabel: Sendable {
    public static func format(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("/") { return trimmed }
        if trimmed.hasPrefix("persona.") { return trimmed }
        if trimmed.contains(".") { return trimmed }
        if trimmed.contains(where: \.isUppercase) { return trimmed }
        return "/\(trimmed)"
    }
}
