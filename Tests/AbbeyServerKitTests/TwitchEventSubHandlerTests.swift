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

    @Test func classifiesUnknownMessageTypeAsIgnored() {
        #expect(TwitchEventSubHandler.handle(
            messageType: "something_new",
            subscriptionType: "channel.update",
            subscriptionStatus: nil
        ) == .ignored(messageType: "something_new", subscriptionType: "channel.update"))
    }

    @Test func logLineMentionsNoProductSideEffectForNotifications() {
        let line = TwitchEventSubHandler.logLine(for: .notificationAcknowledged(subscriptionType: "stream.online"))
        #expect(line.contains("stream.online"))
        #expect(line.contains("no product side-effect"))
    }
}
