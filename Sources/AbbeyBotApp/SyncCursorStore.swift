import AbbeyCore
import Foundation

/// Persists the last *successful* pull boundary so the `?since=` cursor survives relaunch.
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
    static let cursorSetKey = "abbey.sync.pullCursors.v2"

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let cursorSetKey: String

    init(defaults: UserDefaults = .standard, endpoint: String? = nil) {
        self.defaults = defaults
        if let endpoint, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let suffix = SyncEndpointIdentity.storageKey(for: endpoint)
            self.defaultsKey = "\(Self.defaultsKey).\(suffix)"
            self.cursorSetKey = "\(Self.cursorSetKey).\(suffix)"
        } else {
            self.defaultsKey = Self.defaultsKey
            self.cursorSetKey = Self.cursorSetKey
        }
    }

    var lastPullSuccessAt: Date? {
        if let earliest = pullCursors.earliestChangedAt { return earliest }
        guard let raw = defaults.object(forKey: defaultsKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// Loads the v2 per-entity cursor set, or expands the legacy shared timestamp across
    /// all six streams. Migration is persisted on the next successful pull.
    var pullCursors: SyncPullCursorSet {
        if let data = defaults.data(forKey: cursorSetKey),
           let decoded = try? JSONDecoder().decode(SyncPullCursorSet.self, from: data)
        {
            return decoded
        }
        guard let raw = defaults.object(forKey: defaultsKey) as? Double else {
            return SyncPullCursorSet()
        }
        return SyncPullCursorSet(legacyTimestamp: Date(timeIntervalSince1970: raw))
    }

    func record(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: defaultsKey)
    }

    func record(_ cursors: SyncPullCursorSet) {
        guard let data = try? JSONEncoder().encode(cursors) else { return }
        defaults.set(data, forKey: cursorSetKey)
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Apply the post-pull cursor selected from the returned page boundaries.
    /// Failed pulls leave the store untouched; nil deliberately resets to a full pull.
    func applyPullOutcome(nextCursor: Date?, succeeded: Bool) {
        guard succeeded else { return }
        if let nextCursor {
            record(nextCursor)
        } else {
            clear()
        }
    }

    func applyPullOutcome(nextCursors: SyncPullCursorSet, succeeded: Bool) {
        guard succeeded else { return }
        record(nextCursors)
    }

    func clear() {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: cursorSetKey)
    }
}
