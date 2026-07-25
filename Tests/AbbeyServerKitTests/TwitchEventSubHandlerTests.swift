import AbbeyServerKit
import Foundation
import Testing

@Suite("Twitch EventSub per-event handler")
struct TwitchEventSubHandlerTests {
    @Test func classifiesChallenge() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "webhook_callback_verification",
            subscriptionType: "channel.follow",
            subscriptionStatus: nil
        ) == .challenge)
    }

    @Test func classifiesRevocation() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "revocation",
            subscriptionType: "stream.online",
            subscriptionStatus: "authorization_revoked"
        ) == .revocation(subscriptionType: "stream.online", status: "authorization_revoked"))
    }

    @Test func classifiesNotification() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "notification",
            subscriptionType: "channel.follow",
            subscriptionStatus: "enabled"
        ) == .notificationAcknowledged(subscriptionType: "channel.follow"))
    }

    private static let chatMessageBody = Data("""
    {
      "subscription": {"id": "sub-1", "type": "channel.chat.message", "status": "enabled"},
      "event": {
        "broadcaster_user_id": "100",
        "broadcaster_user_login": "somechannel",
        "chatter_user_id": "200",
        "chatter_user_login": "someviewer",
        "message": {"text": "hello abbey"}
      }
    }
    """.utf8)

    @Test func chatMessageNotificationWithPayloadBecomesChatIngest() {
        let outcome = TwitchEventSubHandler.handle(
            messageType: "notification",
            subscriptionType: "channel.chat.message",
            subscriptionStatus: "enabled",
            body: Self.chatMessageBody
        )
        #expect(outcome == .notificationChatIngest(chat: TwitchEventSubChatMessage(
            chatterLogin: "someviewer",
            broadcasterLogin: "somechannel",
            text: "hello abbey"
        )))
    }

    @Test func chatMessageNotificationWithoutBodyFallsBackToAcknowledged() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "notification",
            subscriptionType: "channel.chat.message",
            subscriptionStatus: "enabled",
            body: nil
        ) == .notificationAcknowledged(subscriptionType: "channel.chat.message"))
    }

    @Test func chatMessageNotificationWithMalformedBodyFallsBackToAcknowledged() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "notification",
            subscriptionType: "channel.chat.message",
            subscriptionStatus: "enabled",
            body: Data("{\"event\": {\"message\": {}}}".utf8)
        ) == .notificationAcknowledged(subscriptionType: "channel.chat.message"))
    }

    @Test func otherNotificationTypesIgnoreBodyAndStayLogOnly() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "notification",
            subscriptionType: "channel.follow",
            subscriptionStatus: "enabled",
            body: Self.chatMessageBody
        ) == .notificationAcknowledged(subscriptionType: "channel.follow"))
    }

    private static let streamLifecycleBody = Data("""
    {
      "subscription": {"id": "sub-2", "type": "stream.online", "status": "enabled"},
      "event": {
        "broadcaster_user_id": "100",
        "broadcaster_user_login": "somechannel",
        "type": "live",
        "started_at": "2026-07-25T00:00:00Z"
      }
    }
    """.utf8)

    @Test func streamOnlineNotificationWithPayloadBecomesStreamLifecycle() {
        let outcome = TwitchEventSubHandler.handle(
            messageType: "notification",
            subscriptionType: "stream.online",
            subscriptionStatus: "enabled",
            body: Self.streamLifecycleBody
        )
        #expect(outcome == .notificationStreamOnline(lifecycle: TwitchEventSubStreamLifecycle(
            broadcasterLogin: "somechannel",
            isLive: true
        )))
    }

    @Test func streamOfflineNotificationWithPayloadBecomesStreamLifecycle() {
        let body = Data("""
        {"event": {"broadcaster_user_login": "somechannel"}}
        """.utf8)
        let outcome = TwitchEventSubHandler.handle(
            messageType: "notification",
            subscriptionType: "stream.offline",
            subscriptionStatus: "enabled",
            body: body
        )
        #expect(outcome == .notificationStreamOffline(lifecycle: TwitchEventSubStreamLifecycle(
            broadcasterLogin: "somechannel",
            isLive: false
        )))
    }

    @Test func streamOnlineWithoutBodyFallsBackToAcknowledged() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "notification",
            subscriptionType: "stream.online",
            subscriptionStatus: "enabled",
            body: nil
        ) == .notificationAcknowledged(subscriptionType: "stream.online"))
    }

    @Test func streamOnlineWithMalformedBodyFallsBackToAcknowledged() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "notification",
            subscriptionType: "stream.online",
            subscriptionStatus: "enabled",
            body: Data("{\"event\": {}}".utf8)
        ) == .notificationAcknowledged(subscriptionType: "stream.online"))
    }

    @Test func streamLifecycleLogLineNamesBroadcaster() {
        let online = TwitchEventSubHandler.logLine(for: .notificationStreamOnline(lifecycle: TwitchEventSubStreamLifecycle(
            broadcasterLogin: "somechannel",
            isLive: true
        )))
        #expect(online.contains("somechannel"))
        #expect(online.contains("live"))
        let offline = TwitchEventSubHandler.logLine(for: .notificationStreamOffline(lifecycle: TwitchEventSubStreamLifecycle(
            broadcasterLogin: "somechannel",
            isLive: false
        )))
        #expect(offline.contains("offline"))
    }

    @Test func parseChatMessageRejectsEmptyText() {
        let body = Data("""
        {"event": {"broadcaster_user_login": "c", "chatter_user_login": "v", "message": {"text": "   "}}}
        """.utf8)
        #expect(TwitchEventSubHandler.parseChatMessage(from: body) == nil)
    }

    @Test func chatIngestLogLineNamesChatterAndChannel() {
        let line = TwitchEventSubHandler.logLine(for: .notificationChatIngest(chat: TwitchEventSubChatMessage(
            chatterLogin: "someviewer",
            broadcasterLogin: "somechannel",
            text: "hello abbey"
        )))
        #expect(line.contains("someviewer"))
        #expect(line.contains("somechannel"))
        #expect(line.contains("ingesting"))
    }

    @Test func classifiesUnknownMessageTypeAsIgnored() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "something_new",
            subscriptionType: "channel.update",
            subscriptionStatus: nil
        ) == .ignored(messageType: "something_new", subscriptionType: "channel.update"))
    }

    @Test func logLineMentionsNoProductSideEffectForFollowNotifications() {
        let line = TwitchEventSubHandler.logLine(for: .notificationAcknowledged(subscriptionType: "channel.follow"))
        #expect(line.contains("channel.follow"))
        #expect(line.contains("no product side-effect"))
    }
}
