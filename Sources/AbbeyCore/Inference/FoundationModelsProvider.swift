import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device inference via Apple's Foundation Models framework (macOS 27+).
///
/// Falls back via `InferenceRouter` to the deterministic floor when the framework
/// is missing, unavailable, or throws.
public struct FoundationModelsProvider: InferenceProvider {
    public let mode: InferenceMode = .onDevice

    public func generate(_ request: InferenceRequest) async throws -> InferenceResult {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel(useCase: .general, guardrails: .default)
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw InferenceError.onDeviceUnavailable(String(describing: reason))
        @unknown default:
            throw InferenceError.providerUnavailable(.onDevice)
        }

        let session = LanguageModelSession(
            model: model,
            instructions: Instructions(request.systemPrompt)
        )
        // Instructions live on the session — do not duplicate them in the user turn.
        let prompt = (request.contextLines + [request.userText])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        do {
            let response = try await session.respond(to: prompt)
            return InferenceResult(text: response.content, mode: .onDevice)
        } catch {
            throw InferenceError.onDeviceRequestFailed(String(describing: error))
        }
        #else
        throw InferenceError.providerUnavailable(.onDevice)
        #endif
    }
}
