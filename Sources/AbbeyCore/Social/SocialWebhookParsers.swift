import Foundation

/// Claim-honest parsers for non-Twitch social webhooks → `SocialIngestEnvelope`.
/// These validate shape and extract text; live platform verification is env-gated at the HTTP layer.
public enum SocialWebhookParsers: Sendable {
    /// YouTube PubSubHubbub / push notification atom/json reduced to text.
    public static func youtubePush(body: Data) -> SocialIngestEnvelope? {
        // Prefer JSON bridge shape used by our route: { "channelId", "author", "text", "videoId" }
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let author = (obj["author"] as? String) ?? (obj["channelTitle"] as? String) ?? "youtube"
            let channel = (obj["channelId"] as? String) ?? "unknown"
            let video = (obj["videoId"] as? String) ?? UUID().uuidString
            guard !text.isEmpty else { return nil }
            return SocialIngestEnvelope(
                platform: .youtube,
                guildOrChannelKey: channel,
                authorId: author,
                authorDisplay: author,
                text: text,
                messageId: video,
                rawEventType: "liveChatMessage"
            )
        }
        return nil
    }

    /// X/Twitter CRC challenge is handled by the route; this parses account activity tweet create.
    public static func xTweetCreate(body: Data) -> SocialIngestEnvelope? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        // Simplified: { "data": { "id", "text", "author_id" } } or nested tweet_create_events
        if let data = obj["data"] as? [String: Any],
           let text = (data["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            let id = (data["id"] as? String) ?? UUID().uuidString
            let author = (data["author_id"] as? String) ?? "x-user"
            return SocialIngestEnvelope(
                platform: .x,
                guildOrChannelKey: "home",
                authorId: author,
                authorDisplay: author,
                text: text,
                messageId: id,
                rawEventType: "tweet.create"
            )
        }
        if let events = obj["tweet_create_events"] as? [[String: Any]],
           let first = events.first,
           let text = (first["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            let id = (first["id_str"] as? String) ?? UUID().uuidString
            let author = (first["user"] as? [String: Any])?["screen_name"] as? String ?? "x-user"
            return SocialIngestEnvelope(
                platform: .x,
                guildOrChannelKey: "home",
                authorId: author,
                authorDisplay: author,
                text: text,
                messageId: id,
                rawEventType: "tweet.create"
            )
        }
        return nil
    }

    /// Bluesky firehose/jetstream simplified JSON: { "commit": { "record": { "text" }, "did" } }
    public static func blueskyPost(body: Data) -> SocialIngestEnvelope? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let did = (obj["did"] as? String) ?? "unknown.bsky"
        if let commit = obj["commit"] as? [String: Any],
           let record = commit["record"] as? [String: Any],
           let text = (record["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            let rkey = (commit["rkey"] as? String) ?? UUID().uuidString
            return SocialIngestEnvelope(
                platform: .bluesky,
                guildOrChannelKey: "firehose",
                authorId: did,
                authorDisplay: did,
                text: text,
                messageId: rkey,
                rawEventType: "app.bsky.feed.post"
            )
        }
        if let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return SocialIngestEnvelope(
                platform: .bluesky,
                guildOrChannelKey: "firehose",
                authorId: did,
                authorDisplay: did,
                text: text,
                messageId: UUID().uuidString,
                rawEventType: "app.bsky.feed.post"
            )
        }
        return nil
    }

    /// Mastodon streaming “update” status object.
    public static func mastodonStatus(body: Data) -> SocialIngestEnvelope? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let status = (obj["content"] as? String).map(stripHTML)
            ?? (obj["status"] as? [String: Any]).flatMap { ($0["content"] as? String).map(stripHTML) }
        guard let text = status?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let id = (obj["id"] as? String)
            ?? ((obj["status"] as? [String: Any])?["id"] as? String)
            ?? UUID().uuidString
        let acct = ((obj["account"] as? [String: Any])?["acct"] as? String)
            ?? (((obj["status"] as? [String: Any])?["account"] as? [String: Any])?["acct"] as? String)
            ?? "mastodon"
        return SocialIngestEnvelope(
            platform: .mastodon,
            guildOrChannelKey: "home",
            authorId: acct,
            authorDisplay: acct,
            text: text,
            messageId: id,
            rawEventType: "update"
        )
    }

    public static func parse(platform: SocialPlatform, body: Data) -> SocialIngestEnvelope? {
        switch platform {
        case .youtube: return youtubePush(body: body)
        case .x: return xTweetCreate(body: body)
        case .bluesky: return blueskyPost(body: body)
        case .mastodon: return mastodonStatus(body: body)
        case .twitch, .discord: return nil // dedicated handlers
        }
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
