import AbbeyServerKit
import Crypto
import Foundation
import Testing

@Suite("Twitch EventSub signature verification")
struct TwitchEventSubSignatureTests {
    private let secret = "s3cr3t"
    private let messageId = "abc-123"
    private let timestamp = "2026-07-24T12:00:00.000000000Z"
    private let body = Data(#"{"subscription":{"type":"channel.follow"}}"#.utf8)

    private func validSignature(secret: String, messageId: String, timestamp: String, body: Data) -> String {
        var message = Data(messageId.utf8)
        message.append(Data(timestamp.utf8))
        message.append(body)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return "sha256=\(hex)"
    }

    @Test func acceptsValidSignature() {
        let signature = validSignature(secret: secret, messageId: messageId, timestamp: timestamp, body: body)
        #expect(TwitchEventSubSignature.verify(
            messageId: messageId, timestamp: timestamp, body: body,
            signatureHeader: signature, secret: secret
        ))
    }

    @Test func rejectsTamperedBody() {
        let signature = validSignature(secret: secret, messageId: messageId, timestamp: timestamp, body: body)
        let tamperedBody = Data(#"{"subscription":{"type":"channel.raid"}}"#.utf8)
        #expect(!TwitchEventSubSignature.verify(
            messageId: messageId, timestamp: timestamp, body: tamperedBody,
            signatureHeader: signature, secret: secret
        ))
    }

    @Test func rejectsWrongSecret() {
        let signature = validSignature(secret: secret, messageId: messageId, timestamp: timestamp, body: body)
        #expect(!TwitchEventSubSignature.verify(
            messageId: messageId, timestamp: timestamp, body: body,
            signatureHeader: signature, secret: "wrong-secret"
        ))
    }

    @Test func rejectsMissingSignatureHeader() {
        #expect(!TwitchEventSubSignature.verify(
            messageId: messageId, timestamp: timestamp, body: body,
            signatureHeader: nil, secret: secret
        ))
    }

    @Test func rejectsMalformedSignatureHeader() {
        #expect(!TwitchEventSubSignature.verify(
            messageId: messageId, timestamp: timestamp, body: body,
            signatureHeader: "not-a-real-signature", secret: secret
        ))
    }

    @Test func rejectsOddLengthHexSignature() {
        #expect(!TwitchEventSubSignature.verify(
            messageId: messageId, timestamp: timestamp, body: body,
            signatureHeader: "sha256=abc", secret: secret
        ))
    }

    @Test func replayWindowAcceptsRecentTimestamp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fiveMinutesAgo = ISO8601DateFormatter().string(from: now.addingTimeInterval(-300))
        #expect(TwitchEventSubSignature.isWithinReplayWindow(timestamp: fiveMinutesAgo, now: now))
    }

    @Test func replayWindowRejectsStaleTimestamp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fifteenMinutesAgo = ISO8601DateFormatter().string(from: now.addingTimeInterval(-900))
        #expect(!TwitchEventSubSignature.isWithinReplayWindow(timestamp: fifteenMinutesAgo, now: now))
    }

    @Test func replayWindowRejectsMalformedTimestamp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!TwitchEventSubSignature.isWithinReplayWindow(timestamp: "not-a-timestamp", now: now))
    }
}
