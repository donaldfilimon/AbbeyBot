import Foundation

/// Chooses the next shared `?since=` cursor after a six-entity sync pull.
///
/// Incremental server pages are ordered oldest change first. A short page therefore
/// proves that endpoint was drained through the pull's start time, while a full page
/// may have more rows waiting and can advance only through the newest row it returned.
public enum IncrementalSyncCursor {
    public struct Page: Sendable {
        public var count: Int
        public var newestChangeAt: Date?

        public init(count: Int, newestChangeAt: Date?) {
            self.count = count
            self.newestChangeAt = newestChangeAt
        }
    }

    /// Returns the minimum safe boundary across every entity page.
    ///
    /// A full page without a usable server timestamp conservatively retains the previous
    /// cursor (or nil for a full rescan) instead of skipping an unknown interval.
    public static func next(
        previous: Date?,
        attemptStartedAt: Date,
        limit: Int,
        pages: [Page]
    ) -> Date? {
        guard !pages.isEmpty else { return previous }
        let effectiveLimit = min(max(limit, 1), 500)

        var boundaries: [Date] = []
        for page in pages {
            if page.count < effectiveLimit {
                boundaries.append(attemptStartedAt)
                continue
            }

            guard let serverBoundary = page.newestChangeAt else {
                return previous
            }

            // Never move backward, and never advance beyond the local pull-start guard.
            let monotonicBoundary = previous.map { max($0, serverBoundary) } ?? serverBoundary
            boundaries.append(min(monotonicBoundary, attemptStartedAt))
        }

        return boundaries.min()
    }
}
