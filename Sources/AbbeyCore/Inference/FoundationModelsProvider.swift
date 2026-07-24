import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device inference via Apple's Foundation Models framework.
///
/// Availability and session APIs are gated to macOS 26+. Falls back via
/// `InferenceRouter` to the deterministic floor when the framework is missing,
/// unavailable, or throws.
public struct FoundationModelsProvider: InferenceProvider {
    public let mode: InferenceMode = .onDevice

    public func generate(_ request: InferenceRequest) async throws -> InferenceResult {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw InferenceError.providerUnavailable(.onDevice)
        }

        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw InferenceError.onDeviceUnavailable(String(describing: reason))
        @unknown default:
            throw InferenceError.providerUnavailable(.onDevice)
        }

        let session = LanguageModelSession(model: model, instructions: request.systemPrompt)
        // systemPrompt is already on the session — do not duplicate it in the user turn.
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
