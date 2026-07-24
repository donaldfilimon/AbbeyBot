import Foundation

public struct InferenceRequest: Sendable {
    public var systemPrompt: String
    public var userText: String
    public var contextLines: [String]
    public init(systemPrompt: String, userText: String, contextLines: [String] = []) {
        self.systemPrompt = systemPrompt
        self.userText = userText
        self.contextLines = contextLines
    }
}

public struct InferenceResult: Sendable {
    public var text: String
    public var mode: InferenceMode
    public init(text: String, mode: InferenceMode) {
        self.text = text
        self.mode = mode
    }
}

public enum InferenceError: Error, LocalizedError {
    case providerUnavailable(InferenceMode)
    case remoteEndpointNotConfigured
    case remoteRequestFailed(statusCode: Int?, underlying: String)
    case onDeviceUnavailable(String)
    case onDeviceRequestFailed(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .providerUnavailable(let mode):
            return "Inference mode \(mode.rawValue) is unavailable on this machine."
        case .remoteEndpointNotConfigured:
            return "ABBEY_REMOTE_ENDPOINT is not set; configure it in Settings before using remoteCompatible mode."
        case .remoteRequestFailed(let statusCode, let underlying):
            return "Remote inference request failed (status: \(statusCode.map(String.init) ?? "n/a")): \(underlying)"
        case .onDeviceUnavailable(let reason):
            return "On-device Foundation Models unavailable: \(reason)"
        case .onDeviceRequestFailed(let detail):
            return "On-device Foundation Models request failed: \(detail)"
        case .decodingFailed(let detail):
            return "Could not decode inference response: \(detail)"
        }
    }
}

public protocol InferenceProvider: Sendable {
    var mode: InferenceMode { get }
    func generate(_ request: InferenceRequest) async throws -> InferenceResult
}

/// Picks the right concrete provider given the current `AppConfig.inferenceMode` and
/// falls back to `DeterministicFloorProvider` on any failure, so a bad remote endpoint
/// or an unavailable on-device model never takes Abbey fully offline — it just degrades
/// to rule-based responses. Every fallback is reported through `EventBus` so the
/// Dashboard can surface it rather than hiding it.
public actor InferenceRouter {
    private let deterministicFloor: DeterministicFloorProvider
    private let onDevice: FoundationModelsProvider
    private let remote: RemoteOpenAICompatibleProvider
    private let eventBus: EventBus
    private let metrics: EngineMetrics
    private let currentMode: @Sendable () -> InferenceMode
    private let remoteEndpoint: @Sendable () -> String

    public init(
        eventBus: EventBus,
        metrics: EngineMetrics,
        currentMode: @escaping @Sendable () -> InferenceMode,
        remoteEndpoint: @escaping @Sendable () -> String
    ) {
        self.deterministicFloor = DeterministicFloorProvider()
        self.onDevice = FoundationModelsProvider()
        self.remote = RemoteOpenAICompatibleProvider(endpointProvider: remoteEndpoint)
        self.eventBus = eventBus
        self.metrics = metrics
        self.currentMode = currentMode
        self.remoteEndpoint = remoteEndpoint
    }

    public func generate(_ request: InferenceRequest) async -> InferenceResult {
        let mode = currentMode()
        let provider: any InferenceProvider = {
            switch mode {
            case .deterministicFloor: return deterministicFloor
            case .onDevice: return onDevice
            case .remoteCompatible: return remote
            }
        }()

        do {
            let result = try await provider.generate(request)
            metrics.recordInferenceCall(mode: mode, succeeded: true)
            return result
        } catch {
            metrics.recordInferenceCall(mode: mode, succeeded: false)
            await eventBus.publish(.inferenceProviderFailed(mode: mode, message: error.localizedDescription))
            // Fall through to the deterministic floor unconditionally — it cannot itself throw.
            return (try? await deterministicFloor.generate(request))
                ?? InferenceResult(text: "", mode: .deterministicFloor)
        }
    }
}
