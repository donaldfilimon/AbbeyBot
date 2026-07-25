import Foundation

/// Persists the last *successful* pull time so the `?since=` cursor survives relaunch.
///
/// Without this the cursor lived only in `SyncStatus` (session state), so every launch
/// refetched a full 500-row window before incremental pulls could kick in.
///
/// Stored as a unix-epoch `Double` rather than an archived `Date` so the value stays
/// readable/repairable in `defaults read` and can't fail to decode across OS versions.
/// A missing or non-numeric value degrades to "no cursor" — a full pull, which is always
/// correct, just slower — rather than a bogus cursor that would silently skip rows.
/// `@unchecked Sendable` because `UserDefaults` is documented as thread-safe but isn't
/// marked `Sendable` — same accommodation `AbbeyCore.AppConfig` makes for the same reason.
struct SyncCursorStore: @unchecked Sendable {
    static let defaultsKey = "abbey.sync.lastPullSuccessAt"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastPullSuccessAt: Date? {
        guard let raw = defaults.object(forKey: Self.defaultsKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    func record(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.defaultsKey)
    }

    /// Apply the post-pull cursor update: only advance on success, and always to
    /// `attemptStartedAt` (never completion time). Failed pulls leave the store untouched.
    func applyPullOutcome(attemptStartedAt: Date, succeeded: Bool) {
        guard succeeded else { return }
        record(attemptStartedAt)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
