import Foundation

/// The always-available fallback: no model call, no network, no on-device model load.
/// Uses `IntentClassifier` + small template banks keyed by persona register, so Abbey
/// never goes fully silent even with every model path unavailable.
public struct DeterministicFloorProvider: InferenceProvider {
    public let mode: InferenceMode = .deterministicFloor

    private static let acknowledgements = [
        "Got it.", "Noted.", "On it.", "Makes sense."
    ]
    private static let questionFallbacks = [
        "Don't have a model call available right now — here's what I can tell from context: ",
        "Running rule-based only at the moment. Best I've got: "
    ]

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
            text = Self.acknowledgements.randomElement() ?? "Noted."
        }
        return InferenceResult(text: text, mode: .deterministicFloor)
    }
}
