import Foundation

/// Industry tone overlay for inference prompts. Not a compliance product —
/// no HIPAA/GDPR certification claims.
public enum IndustryProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case general
    case healthcare
    case finance
    case legal

    public var id: String { rawValue }

    /// Short suffix appended to the active persona system prompt.
    public var promptSuffix: String {
        switch self {
        case .general:
            return ""
        case .healthcare:
            return """
             Industry context: healthcare community tone. Give general information only; \
            recommend consulting a qualified professional for medical decisions. Do not invent \
            certifications or claim HIPAA product compliance.
            """
        case .finance:
            return """
             Industry context: finance community tone. Be precise about uncertainty; do not give \
            personalized investment advice or claim regulatory licenses.
            """
        case .legal:
            return """
             Industry context: legal community tone. Provide general information only; recommend \
            consulting a licensed attorney. Do not claim to practice law.
            """
        }
    }

    public static func resolve(_ raw: String?) -> IndustryProfile {
        guard let raw, let value = IndustryProfile(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return .general
        }
        return value
    }
}
