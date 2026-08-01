import AbbeyCore
import AbbeyServerKit
import Foundation
import Vapor

struct SocialCatalogDTO: Content {
    var platforms: [SocialPlatformDTO]
}

struct SocialPlatformDTO: Content {
    var id: String
    var name: String
    var baseURL: String
    var docsURL: String
    var rateLimitHint: String
    var endpoints: Int
    var eventsShipped: Int
    var eventsTotal: Int
    var envKeys: [String]
}

struct SocialIngestBodyDTO: Content {
    var text: String?
    var author: String?
    var channelId: String?
    var messageId: String?
    // raw passthrough — parsers may use whole JSON
}

enum SocialRoutes {
    static func register(on app: Application) {
        app.get("api", "social", "catalog") { req async throws -> SocialCatalogDTO in
            try AbbeyAPIAuth.requireTokenIfConfigured(req)
            let platforms = SocialAPICatalog.all.map { p in
                SocialPlatformDTO(
                    id: p.platform.rawValue,
                    name: p.platform.displayName,
                    baseURL: p.baseURL,
                    docsURL: p.docsURL,
                    rateLimitHint: p.rateLimitHint,
                    endpoints: p.endpoints.count,
                    eventsShipped: p.events.filter(\.shipped).count,
                    eventsTotal: p.events.count,
                    envKeys: p.envKeys
                )
            }
            return SocialCatalogDTO(platforms: platforms)
        }

        app.get("api", "social", "catalog", "markdown") { req async throws -> Response in
            try AbbeyAPIAuth.requireTokenIfConfigured(req)
            var headers = HTTPHeaders()
            headers.contentType = .plainText
            return Response(
                status: .ok,
                headers: headers,
                body: .init(string: SocialAPICatalog.markdownOverview())
            )
        }

        // Generic social webhook: POST /api/social/:platform/webhook
        app.post("api", "social", ":platform", "webhook") { req async throws -> Response in
            try AbbeyAPIAuth.requireConfiguredToken(
                req,
                allowingExplicitBypass: "ABBEY_ALLOW_UNSIGNED_SOCIAL_WEBHOOKS_FOR_TESTING"
            )
            let platformName = req.parameters.get("platform") ?? ""
            guard let platform = SocialPlatform(rawValue: platformName.lowercased()) else {
                throw Abort(.badRequest, reason: "unknown platform (twitch|youtube|x|bluesky|mastodon)")
            }
            if platform == .twitch {
                throw Abort(
                    .badRequest,
                    reason: "use POST /api/twitch/eventsub for Twitch EventSub (HMAC verified)"
                )
            }
            guard let bodyBuffer = req.body.data else {
                throw Abort(.badRequest, reason: "Missing body")
            }
            let raw = Data(bodyBuffer.readableBytesView)
            guard let envelope = SocialWebhookParsers.parse(platform: platform, body: raw) else {
                throw Abort(.unprocessableEntity, reason: "could not parse \(platform.rawValue) payload")
            }
            await req.application.botRuntime.handleSocialEnvelope(envelope)
            return try await TwitchEventSubAckDTO(
                ok: true,
                handled: true,
                duplicate: false,
                outcome: "social-accepted-\(platform.rawValue)"
            ).encodeResponse(for: req)
        }
    }
}
