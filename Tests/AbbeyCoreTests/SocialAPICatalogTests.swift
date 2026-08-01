import Foundation
import Testing
@testable import AbbeyCore

@Suite("Social API catalog + webhook parsers")
struct SocialAPICatalogTests {
    @Test func catalogCoversMajorPlatforms() {
        let ids = Set(SocialAPICatalog.all.map(\.platform))
        for p in SocialPlatform.allCases {
            #expect(ids.contains(p))
        }
        #expect(SocialAPICatalog.twitch.events.contains(where: { $0.name == "channel.chat.message" && $0.shipped }))
    }

    @Test func classifierDetectsTwitchHeaders() {
        let p = SocialWebhookClassifier.platform(
            path: "/api/hooks",
            headers: ["Twitch-Eventsub-Message-Id": "abc"]
        )
        #expect(p == .twitch)
        #expect(SocialWebhookClassifier.platform(path: "/api/social/youtube/webhook") == .youtube)
    }

    @Test func parseYoutubeJSON() throws {
        let json = """
        {"channelId":"UC1","author":"Alice","text":"hello chat","videoId":"v1"}
        """
        let env = SocialWebhookParsers.youtubePush(body: Data(json.utf8))
        #expect(env?.text == "hello chat")
        #expect(env?.platform == .youtube)
        #expect(env?.ingestGuildId == "youtube")
    }

    @Test func parseXTweetData() throws {
        let json = """
        {"data":{"id":"99","text":"ship it","author_id":"42"}}
        """
        let env = SocialWebhookParsers.xTweetCreate(body: Data(json.utf8))
        #expect(env?.text == "ship it")
        #expect(env?.messageId == "99")
    }

    @Test func parseBlueskyPost() throws {
        let json = """
        {"did":"did:plc:abc","commit":{"rkey":"r1","record":{"text":"hello bsky"}}}
        """
        let env = SocialWebhookParsers.blueskyPost(body: Data(json.utf8))
        #expect(env?.text == "hello bsky")
        #expect(env?.authorId == "did:plc:abc")
    }

    @Test func markdownOverviewNonEmpty() {
        let md = SocialAPICatalog.markdownOverview()
        #expect(md.contains("Twitch"))
        #expect(md.contains("Bluesky"))
    }
}
