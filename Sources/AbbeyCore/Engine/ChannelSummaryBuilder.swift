import Foundation

/// Deterministic channel summary from recent messages (most-recent-N, truncated lines).
public enum ChannelSummaryBuilder: Sendable {
    public struct Line: Sendable {
        public var authorId: String
        public var content: String
        public init(authorId: String, content: String) {
            self.authorId = authorId
            self.content = content
        }
    }

    /// `lines` should be oldest → newest for a readable transcript.
    public static func summarize(_ lines: [Line], maxContentChars: Int = 120) -> String {
        lines
            .map { "\($0.authorId): \($0.content.prefix(maxContentChars))" }
            .joined(separator: "\n")
    }
}
