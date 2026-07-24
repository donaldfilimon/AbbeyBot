import Foundation
import Observation

/// Last server-sync outcome for Settings. Updated by `AbbeyServerClient` / pull on the main actor.
@Observable
@MainActor
final class SyncStatus {
    static let shared = SyncStatus()

    // MARK: - Push (POST mirror)

    private(set) var lastSuccessAt: Date?
    private(set) var lastFailureAt: Date?
    private(set) var lastPath: String?
    private(set) var lastError: String?

    // MARK: - Pull

    private(set) var isPulling: Bool = false
    private(set) var lastPullSuccessAt: Date?
    private(set) var lastPullFailureAt: Date?
    private(set) var lastPullError: String?
    private(set) var lastPullUsersUpserted: Int = 0
    private(set) var lastPullChannelsUpserted: Int = 0
    private(set) var lastPullMessagesInserted: Int = 0
    private(set) var lastPullReputationInserted: Int = 0
    private(set) var lastPullInteractionsInserted: Int = 0
    private(set) var lastPullEquityUpserted: Int = 0

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

    /// Starts a pull if none is in flight. Returns `false` when a pull is already running.
    @discardableResult
    func beginPull() -> Bool {
        if isPulling { return false }
        isPulling = true
        return true
    }

    func recordPullSuccess(
        users: Int,
        channels: Int,
        messages: Int,
        reputation: Int,
        interactions: Int,
        equity: Int
    ) {
        isPulling = false
        lastPullSuccessAt = .now
        lastPullError = nil
        lastPullUsersUpserted = users
        lastPullChannelsUpserted = channels
        lastPullMessagesInserted = messages
        lastPullReputationInserted = reputation
        lastPullInteractionsInserted = interactions
        lastPullEquityUpserted = equity
    }

    func recordPullFailure(message: String) {
        isPulling = false
        lastPullFailureAt = .now
        lastPullError = message
    }

    var summary: String {
        if let err = lastError, let path = lastPath, let at = lastFailureAt {
            return "Last push failure: \(path) — \(err) (\(relative(at)))"
        }
        if let path = lastPath, let at = lastSuccessAt {
            return "Last push OK: \(path) (\(relative(at)))"
        }
        return "No push attempts yet this session."
    }

    var pullSummary: String {
        if isPulling {
            return "Pulling from server…"
        }
        if let err = lastPullError, let at = lastPullFailureAt {
            return "Last pull failure: \(err) (\(relative(at)))"
        }
        if let at = lastPullSuccessAt {
            return "Last pull OK: \(lastPullUsersUpserted) users, \(lastPullChannelsUpserted) channels, \(lastPullMessagesInserted) messages, \(lastPullReputationInserted) reputation, \(lastPullInteractionsInserted) interactions, \(lastPullEquityUpserted) equity (\(relative(at)))"
        }
        return "No pull attempts yet this session."
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
