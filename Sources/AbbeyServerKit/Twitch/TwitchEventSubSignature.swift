import Crypto
import Foundation

/// Verifies Twitch EventSub webhook signatures per
/// https://dev.twitch.tv/docs/eventsub/handling-webhook-events/#verifying-the-event-message
public enum TwitchEventSubSignature {
    /// `body` must be the exact raw request bytes Twitch sent — decoding and
    /// re-encoding the payload changes whitespace/key order and breaks the HMAC.
    public static func verify(
        messageId: String,
        timestamp: String,
        body: Data,
        signatureHeader: String?,
        secret: String
    ) -> Bool {
        guard let signatureHeader, signatureHeader.hasPrefix("sha256=") else { return false }
        guard let expectedMAC = Data(hexEncoded: String(signatureHeader.dropFirst("sha256=".count))) else {
            return false
        }

        var message = Data(messageId.utf8)
        message.append(Data(timestamp.utf8))
        message.append(body)

        let key = SymmetricKey(data: Data(secret.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(expectedMAC, authenticating: message, using: key)
    }

    /// Rejects timestamps outside `window` seconds of `now`, guarding against replay of a
    /// captured request. Twitch does not dedupe deliveries for you.
    public static func isWithinReplayWindow(timestamp: String, now: Date, window: TimeInterval = 600) -> Bool {
        guard let parsed = parseTimestamp(timestamp) else { return false }
        return abs(now.timeIntervalSince(parsed)) <= window
    }

    private static func parseTimestamp(_ timestamp: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: timestamp) {
            return date
        }
        return ISO8601DateFormatter().date(from: timestamp)
    }
}

private extension Data {
    init?(hexEncoded hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
