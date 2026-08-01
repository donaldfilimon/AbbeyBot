import Foundation

/// Chooses the next shared `?since=` cursor after a six-entity sync pull.
///
/// Incremental server pages are ordered oldest change first. A short page therefore
/// proves that endpoint was drained through the pull's start time, while a full page
/// may have more rows waiting and can advance only through the newest row it returned.
public enum IncrementalSyncCursor {
    /// One independently advancing entity stream.
    /// A short page is drained through pull start; a full page advances only through the
    /// exact server-issued `(timestamp, stable ID)` boundary.
    public static func next(
        previous: SyncPullCursor?,
        attemptStartedAt: Date,
        limit: Int,
        rowCount: Int,
        serverBoundary: SyncPullCursor?,
        serverHighWatermark: Date? = nil
    ) -> SyncPullCursor? {
        let effectiveLimit = min(max(limit, 1), 500)
        let safeUpperBound = serverHighWatermark ?? attemptStartedAt
        guard rowCount >= effectiveLimit else {
            // Short page: no stable ID on this boundary — a bare `changedAt` degrades this
            // stream to strict `timestamp > since` until the next full page re-establishes a
            // tie-breaker. Acceptable: `safeUpperBound` is captured once per request essentially
            // "now" relative to the read, while every row's `changedAt` was set at its own,
            // necessarily earlier, write — an exact collision would need a row to land in that
            // same instant, which sub-millisecond `Date` precision makes vanishingly unlikely in
            // practice even though both timestamps share the server's clock domain.
            return SyncPullCursor(changedAt: safeUpperBound)
        }
        guard let serverBoundary else { return previous }
        guard serverBoundary.changedAt <= safeUpperBound else {
            return SyncPullCursor(changedAt: safeUpperBound)
        }
        if let previous {
            if serverBoundary.changedAt < previous.changedAt { return previous }
            if serverBoundary.changedAt == previous.changedAt,
               let previousID = previous.stableID,
               let boundaryID = serverBoundary.stableID,
               boundaryID <= previousID
            {
                return previous
            }
        }
        return serverBoundary
    }
}
