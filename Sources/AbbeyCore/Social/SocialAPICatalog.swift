import Foundation

/// Platform id for multi-network ingest / webhook routing.
public enum SocialPlatform: String, CaseIterable, Sendable, Codable {
    case twitch
    case discord
    case youtube
    case x
    case bluesky
    case mastodon

    public var displayName: String {
        switch self {
        case .twitch: return "Twitch"
        case .discord: return "Discord"
        case .youtube: return "YouTube"
        case .x: return "X (Twitter)"
        case .bluesky: return "Bluesky"
        case .mastodon: return "Mastodon"
        }
    }
}

/// How a client authenticates to the platform API.
public enum SocialAuthStyle: String, Sendable, Codable {
    case oauth2App
    case oauth2User
    case bearer
    case botToken
    case hmacWebhook
    case none
}

/// Documented API surface (claim-honest: catalog for smart routing / operator UX, not live SDKs for every network).
public struct SocialAPIEndpoint: Sendable, Equatable, Codable {
    public var method: String
    public var path: String
    public var purpose: String
    public var auth: SocialAuthStyle

    public init(method: String, path: String, purpose: String, auth: SocialAuthStyle) {
        self.method = method
        self.path = path
        self.purpose = purpose
        self.auth = auth
    }
}

public struct SocialEventType: Sendable, Equatable, Codable {
    public var name: String
    public var productEffect: String
    public var capability: SocialCapabilityLevel

    /// Compatibility projection for existing operator UI.  Only verified webhooks and live
    /// clients count as shipped platform integrations; a JSON adapter is intentionally not
    /// promoted to a native platform claim.
    public var shipped: Bool { capability == .verifiedWebhook || capability == .liveClient }

    public init(name: String, productEffect: String, capability: SocialCapabilityLevel) {
        self.name = name
        self.productEffect = productEffect
        self.capability = capability
    }
}

public enum SocialCapabilityLevel: String, Sendable, Equatable, Codable {
    case catalogOnly
    case customPayloadParser
    case verifiedWebhook
    case liveClient
}

public struct SocialPlatformProfile: Sendable, Equatable, Codable {
    public var platform: SocialPlatform
    public var baseURL: String
    public var docsURL: String
    public var rateLimitHint: String
    public var endpoints: [SocialAPIEndpoint]
    public var events: [SocialEventType]
    public var envKeys: [String]

    public init(
        platform: SocialPlatform,
        baseURL: String,
        docsURL: String,
        rateLimitHint: String,
        endpoints: [SocialAPIEndpoint],
        events: [SocialEventType],
        envKeys: [String]
    ) {
        self.platform = platform
        self.baseURL = baseURL
        self.docsURL = docsURL
        self.rateLimitHint = rateLimitHint
        self.endpoints = endpoints
        self.events = events
        self.envKeys = envKeys
    }
}

/// Static knowledge base of social APIs Abbey understands for routing, docs, and status.
public enum SocialAPICatalog: Sendable {
    public static var all: [SocialPlatformProfile] {
        [twitch, discord, youtube, x, bluesky, mastodon]
    }

    public static func profile(for platform: SocialPlatform) -> SocialPlatformProfile {
        switch platform {
        case .twitch: return twitch
        case .discord: return discord
        case .youtube: return youtube
        case .x: return x
        case .bluesky: return bluesky
        case .mastodon: return mastodon
        }
    }

    public static let twitch = SocialPlatformProfile(
        platform: .twitch,
        baseURL: "https://api.twitch.tv/helix",
        docsURL: "https://dev.twitch.tv/docs/api/",
        rateLimitHint: "Helix ~800 points / minute (app); EventSub webhooks separate",
        endpoints: [
            .init(method: "POST", path: "https://id.twitch.tv/oauth2/token", purpose: "App access token (client credentials)", auth: .oauth2App),
            .init(method: "GET", path: "/users", purpose: "Resolve logins → user ids", auth: .oauth2App),
            .init(method: "GET", path: "/streams", purpose: "Live stream status", auth: .oauth2App),
            .init(method: "GET", path: "/channels", purpose: "Channel metadata", auth: .oauth2App),
            .init(method: "POST", path: "/eventsub/subscriptions", purpose: "Create EventSub webhook", auth: .oauth2App),
            .init(method: "GET", path: "/eventsub/subscriptions", purpose: "List EventSub subscriptions", auth: .oauth2App),
        ],
        events: [
            .init(name: "channel.chat.message", productEffect: "TLS IRC / verified EventSub → ingest + reply", capability: .liveClient),
            .init(name: "stream.online", productEffect: "verified EventSub → twitchStreamLive=true", capability: .verifiedWebhook),
            .init(name: "stream.offline", productEffect: "verified EventSub → twitchStreamLive=false", capability: .verifiedWebhook),
            .init(name: "channel.follow", productEffect: "verified EventSub → interaction + scoped note", capability: .verifiedWebhook),
            .init(name: "channel.subscribe", productEffect: "verified EventSub → interaction + scoped note", capability: .verifiedWebhook),
            .init(name: "channel.cheer", productEffect: "verified EventSub → interaction + scoped note", capability: .verifiedWebhook),
            .init(name: "channel.raid", productEffect: "catalog only", capability: .catalogOnly),
        ],
        envKeys: [
            "TWITCH_OAUTH_TOKEN", "TWITCH_BOT_LOGIN", "TWITCH_CHANNEL",
            "TWITCH_CLIENT_ID", "TWITCH_CLIENT_SECRET", "TWITCH_EVENTSUB_SECRET",
            "TWITCH_EVENTSUB_CALLBACK_URL", "TWITCH_BROADCASTER_USER_ID", "TWITCH_BOT_USER_ID",
            "ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE",
        ]
    )

    public static let discord = SocialPlatformProfile(
        platform: .discord,
        baseURL: "https://discord.com/api/v10",
        docsURL: "https://discord.com/developers/docs/",
        rateLimitHint: "Global + per-route buckets; gateway separate from REST",
        endpoints: [
            .init(method: "GET", path: "/users/@me", purpose: "Bot identity", auth: .botToken),
            .init(method: "POST", path: "/interactions/{id}/{token}/callback", purpose: "Slash ack", auth: .botToken),
            .init(method: "PUT", path: "/applications/{id}/commands", purpose: "Register slash commands", auth: .botToken),
        ],
        events: [
            .init(name: "MESSAGE_CREATE", productEffect: "gateway ingest + craftReply", capability: .liveClient),
            .init(name: "INTERACTION_CREATE", productEffect: "authorized slash router", capability: .liveClient),
            .init(name: "VOICE_STATE_UPDATE", productEffect: "presence only", capability: .liveClient),
        ],
        envKeys: ["DISCORD_BOT_TOKEN", "DISCORD_DEV_GUILD_ID"]
    )

    public static let youtube = SocialPlatformProfile(
        platform: .youtube,
        baseURL: "https://www.googleapis.com/youtube/v3",
        docsURL: "https://developers.google.com/youtube/v3",
        rateLimitHint: "Quota units per day (default 10k); liveChat separate",
        endpoints: [
            .init(method: "GET", path: "/search", purpose: "Channel/video search", auth: .bearer),
            .init(method: "GET", path: "/liveChat/messages", purpose: "Poll live chat", auth: .oauth2User),
            .init(method: "POST", path: "/liveChat/messages", purpose: "Post live chat", auth: .oauth2User),
        ],
        events: [
            .init(name: "liveChatMessage", productEffect: "authenticated custom JSON adapter → envelope (not native PubSub/polling)", capability: .customPayloadParser),
        ],
        envKeys: ["YOUTUBE_API_KEY", "YOUTUBE_OAUTH_TOKEN", "YOUTUBE_LIVE_CHAT_ID"]
    )

    public static let x = SocialPlatformProfile(
        platform: .x,
        baseURL: "https://api.x.com/2",
        docsURL: "https://developer.x.com/en/docs/twitter-api",
        rateLimitHint: "Per-endpoint app/user caps; filtered stream separate",
        endpoints: [
            .init(method: "GET", path: "/tweets/search/recent", purpose: "Recent search", auth: .bearer),
            .init(method: "POST", path: "/tweets", purpose: "Post tweet", auth: .oauth2User),
            .init(method: "GET", path: "/tweets/search/stream", purpose: "Filtered stream", auth: .bearer),
        ],
        events: [
            .init(name: "tweet.create", productEffect: "authenticated custom JSON adapter → envelope (no native CRC route)", capability: .customPayloadParser),
        ],
        envKeys: ["X_BEARER_TOKEN", "X_API_KEY", "X_API_SECRET", "X_WEBHOOK_SECRET"]
    )

    public static let bluesky = SocialPlatformProfile(
        platform: .bluesky,
        baseURL: "https://bsky.social/xrpc",
        docsURL: "https://docs.bsky.app/",
        rateLimitHint: "PDS-dependent; firehose/jetstream separate",
        endpoints: [
            .init(method: "POST", path: "/com.atproto.server.createSession", purpose: "App password login", auth: .oauth2User),
            .init(method: "GET", path: "/app.bsky.feed.getTimeline", purpose: "Home timeline", auth: .bearer),
            .init(method: "POST", path: "/com.atproto.repo.createRecord", purpose: "Create post", auth: .bearer),
        ],
        events: [
            .init(name: "app.bsky.feed.post", productEffect: "authenticated custom JSON adapter → envelope (no firehose client)", capability: .customPayloadParser),
        ],
        envKeys: ["BLUESKY_HANDLE", "BLUESKY_APP_PASSWORD", "BLUESKY_PDS"]
    )

    public static let mastodon = SocialPlatformProfile(
        platform: .mastodon,
        baseURL: "https://{instance}/api/v1",
        docsURL: "https://docs.joinmastodon.org/client/intro/",
        rateLimitHint: "Instance-specific; streaming API separate",
        endpoints: [
            .init(method: "GET", path: "/timelines/home", purpose: "Home timeline", auth: .bearer),
            .init(method: "POST", path: "/statuses", purpose: "Post status", auth: .bearer),
            .init(method: "GET", path: "/streaming", purpose: "SSE/WebSocket stream", auth: .bearer),
        ],
        events: [
            .init(name: "update", productEffect: "authenticated custom JSON adapter → envelope (no streaming client)", capability: .customPayloadParser),
        ],
        envKeys: ["MASTODON_INSTANCE", "MASTODON_ACCESS_TOKEN"]
    )

    /// Operator-facing markdown summary.
    public static func markdownOverview() -> String {
        var lines = ["**Social API catalog** (understanding + routing; live depth varies by platform)", ""]
        for p in all {
            let live = p.events.filter { $0.capability == .liveClient }.count
            let verified = p.events.filter { $0.capability == .verifiedWebhook }.count
            let adapters = p.events.filter { $0.capability == .customPayloadParser }.count
            let catalogOnly = p.events.filter { $0.capability == .catalogOnly }.count
            lines.append("### \(p.platform.displayName)")
            lines.append("- Base: `\(p.baseURL)`")
            lines.append("- Docs: \(p.docsURL)")
            lines.append("- Rate: \(p.rateLimitHint)")
            lines.append(
                "- Endpoints catalogued: \(p.endpoints.count); capabilities live=\(live), verified-webhook=\(verified), custom-adapter=\(adapters), catalog-only=\(catalogOnly)"
            )
            lines.append("- Env: \(p.envKeys.joined(separator: ", "))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// Normalized chat/social message for shared ingest (Discord/Twitch/YouTube/…).
public struct SocialIngestEnvelope: Sendable, Equatable, Codable {
    public var platform: SocialPlatform
    public var guildOrChannelKey: String
    public var authorId: String
    public var authorDisplay: String
    public var text: String
    public var messageId: String
    public var rawEventType: String
    public var createdAt: Date

    public init(
        platform: SocialPlatform,
        guildOrChannelKey: String,
        authorId: String,
        authorDisplay: String,
        text: String,
        messageId: String,
        rawEventType: String,
        createdAt: Date = .now
    ) {
        self.platform = platform
        self.guildOrChannelKey = guildOrChannelKey
        self.authorId = authorId
        self.authorDisplay = authorDisplay
        self.text = text
        self.messageId = messageId
        self.rawEventType = rawEventType
        self.createdAt = createdAt
    }

    /// Map to Abbey ingest guild/channel ids (`guildId` namespace by platform).
    public var ingestGuildId: String { platform.rawValue }
    public var ingestChannelId: String { guildOrChannelKey }
    public var ingestAuthorId: String { authorId }
}

/// Lightweight classifier for inbound social webhooks (content-type / path / headers).
public enum SocialWebhookClassifier: Sendable {
    public static func platform(
        path: String,
        headers: [String: String] = [:]
    ) -> SocialPlatform? {
        let p = path.lowercased()
        if p.contains("twitch") || headers.keys.contains(where: { $0.lowercased().hasPrefix("twitch-eventsub") }) {
            return .twitch
        }
        if p.contains("youtube") || p.contains("pubsubhubbub") { return .youtube }
        if p.contains("/x/") || p.contains("twitter") { return .x }
        if p.contains("bsky") || p.contains("bluesky") { return .bluesky }
        if p.contains("mastodon") { return .mastodon }
        if p.contains("discord") { return .discord }
        return nil
    }
}
