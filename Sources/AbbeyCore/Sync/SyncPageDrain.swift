import Foundation

public enum SyncPageDrainError: Error, LocalizedError, Equatable, Sendable {
    case stalled
    case pageLimitExceeded(Int)

    public var errorDescription: String? {
        switch self {
        case .stalled:
            return "Sync page was full but did not publish a newer cursor"
        case .pageLimitExceeded(let limit):
            return "Sync exceeded the safety ceiling of \(limit) pages for one entity"
        }
    }
}

public struct SyncPageDrainResult<Row: Sendable>: Sendable {
    public var rows: [Row]
    public var nextCursor: SyncPullCursor?
    public var pageCount: Int

    public init(rows: [Row], nextCursor: SyncPullCursor?, pageCount: Int) {
        self.rows = rows
        self.nextCursor = nextCursor
        self.pageCount = pageCount
    }
}

/// Drains one oldest-first entity stream through a short page. A bounded ceiling prevents
/// a hot or malformed endpoint from holding one desktop/CLI operation forever.
public enum SyncPageDrain: Sendable {
    public static func run<Row: Sendable>(
        initialCursor: SyncPullCursor,
        attemptStartedAt: Date,
        limit: Int = 500,
        maxPages: Int = 20,
        fetch: @Sendable (SyncPullCursor) async throws -> SyncPullPage<Row>
    ) async throws -> SyncPageDrainResult<Row> {
        let effectiveLimit = min(max(limit, 1), 500)
        let effectiveMaxPages = max(maxPages, 1)
        var cursor = initialCursor
        var rows: [Row] = []

        for pageNumber in 1...effectiveMaxPages {
            let page = try await fetch(cursor)
            rows.append(contentsOf: page.rows)
            let planned = IncrementalSyncCursor.next(
                previous: cursor,
                attemptStartedAt: attemptStartedAt,
                limit: effectiveLimit,
                rowCount: page.rows.count,
                serverBoundary: page.serverBoundary,
                serverHighWatermark: page.serverHighWatermark
            )

            if page.rows.count < effectiveLimit {
                return SyncPageDrainResult(rows: rows, nextCursor: planned, pageCount: pageNumber)
            }
            guard let planned, planned != cursor else {
                throw SyncPageDrainError.stalled
            }
            cursor = planned
        }

        throw SyncPageDrainError.pageLimitExceeded(effectiveMaxPages)
    }
}
