import Foundation
import Observation

/// Last server-sync outcome for Settings. Updated by `AbbeyServerClient` on the main actor.
@Observable
@MainActor
final class SyncStatus {
    static let shared = SyncStatus()

    private(set) var lastSuccessAt: Date?
    private(set) var lastFailureAt: Date?
    private(set) var lastPath: String?
    private(set) var lastError: String?

    private init() {}

    func recordSuccess(path: String) {
        lastSuccessAt = .now
        lastPath = path
        lastError = nil
    }

    func recordFailure(path: String, message: String) {
        lastFailureAt = .now
        lastPath = path
        lastError = message
    }

    var summary: String {
        if let err = lastError, let path = lastPath, let at = lastFailureAt {
            return "Last failure: \(path) — \(err) (\(relative(at)))"
        }
        if let path = lastPath, let at = lastSuccessAt {
            return "Last sync OK: \(path) (\(relative(at)))"
        }
        return "No sync attempts yet this session."
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
