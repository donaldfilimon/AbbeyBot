import Foundation

/// Query-string construction for AbbeyServer's list endpoints, kept separate from
/// `AbbeyServerClient` so the wire format can be unit-tested without a URLSession.
///
/// The server clamps `limit` to 1...500 and parses `since` as a unix-epoch `Double`
/// (`AbbeyServer`'s `sinceParam(_:)`), so this must emit that exact shape.
enum SyncQuery {
    static let maxLimit = 500

    static func listItems(limit: Int, since: Date?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), maxLimit)))]
        if let since {
            items.append(URLQueryItem(name: "since", value: String(since.timeIntervalSince1970)))
        }
        return items
    }
}
