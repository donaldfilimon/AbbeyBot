import AbbeyCore
import AbbeyServerKit
import Vapor

/// The ack body every inbound platform webhook returns — Twitch EventSub and the generic
/// social receivers alike. Construct it through the factories below rather than by hand: the
/// three flags are not independent, and spelling them out at each call site is how the Twitch
/// and social routes drifted into reporting the same ingest outcome under different labels.
struct WebhookAckDTO: Content {
    var ok: Bool
    var handled: Bool
    var duplicate: Bool?
    var outcome: String?

    /// The event changed durable state.
    static func handled(_ outcome: String) -> Self {
        .init(ok: true, handled: true, duplicate: false, outcome: outcome)
    }

    /// The event was understood and accepted, but intentionally changed nothing.
    static func acknowledged(_ outcome: String) -> Self {
        .init(ok: true, handled: false, duplicate: false, outcome: outcome)
    }

    /// The platform redelivered something already stored. Reserved for *delivery* replays —
    /// never for "we chose not to process this", which is `acknowledged`.
    static let duplicate = Self(ok: true, handled: false, duplicate: true, outcome: "duplicate")

    /// Single mapping from an ingest result to an ack, shared by every webhook that ends in
    /// `ingestMessageOutcome`. Throws on persistence failure so the caller can answer with a
    /// retryable status instead of acking a delivery it dropped.
    static func forIngest(_ outcome: MessageIngestOutcome, inserted: String) throws -> Self {
        switch outcome {
        case .inserted: return .handled(inserted)
        case .duplicate: return .duplicate
        case .failed: throw BotRuntimeEventProcessingError.ingestFailed
        }
    }
}
