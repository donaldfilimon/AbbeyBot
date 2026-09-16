import Foundation

/// The always-available fallback: no model call, no network, no on-device model load.
/// Uses `IntentClassifier` + small template banks keyed by **intent**, so Abbey never
/// goes fully silent even with every model path unavailable.
///
/// The banks are not keyed by persona: `generate` never reads
/// `InferenceRequest.systemPrompt`, so Abbey, Aviva and Abi emit byte-identical
/// text in floor mode. That is a real limitation of the floor, not an oversight
/// to paper over in prose — an earlier version of this comment claimed the banks
/// were "keyed by persona register", which they have never been.
public struct DeterministicFloorProvider: InferenceProvider {
    public let mode: InferenceMode = .deterministicFloor

    private static let acknowledgements = [
        "Got it.", "Noted.", "On it.", "Makes sense."
    ]
    private static let questionFallbacks = [
        "Don't have a model call available right now — here's what I can tell from context: ",
        "Running rule-based only at the moment. Best I've got: "
    ]

    /// Pick a bank entry from the request itself, so identical input always
    /// yields identical output.
    ///
    /// This replaced `randomElement()`, which made a provider named
    /// *Deterministic*, reporting `mode: .deterministicFloor`, return different
    /// text for the same message — defeating reproducibility on the one path
    /// that is supposed to hold when every model is unavailable.
    ///
    /// FNV-1a rather than `hashValue`: Swift seeds `Hasher` per process, so
    /// `hashValue` would still vary between runs and reintroduce the same bug
    /// in a less obvious form.
    static func stableIndex(for text: String, upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(upperBound))
    }

    public func generate(_ request: InferenceRequest) async throws -> InferenceResult {
        let intent = IntentClassifier.classify(request.userText)
        let text: String
        switch intent {
        case .greeting:
            text = "Hey."
        case .question:
            let lastContextLine = request.contextLines.last ?? "no recent channel context"
            text = Self.questionFallbacks.first! + lastContextLine
        case .command:
            text = "Command noted — deterministic floor mode doesn't execute side effects itself; route through the appropriate handler."
        default:
            text = Self.acknowledgements[
                Self.stableIndex(for: request.userText, upperBound: Self.acknowledgements.count)
            ]
        }
        return InferenceResult(text: text, mode: .deterministicFloor)
    }
}
