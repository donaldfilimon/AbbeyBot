import CoreFoundation
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

public enum InferenceCapability: String, Codable, CaseIterable, Sendable {
    case text
    case structuredJSON
    case boundedPlanning
}

public enum InferenceFallbackPolicy: Sendable, Equatable {
    case allowDeterministicFloor
    case require(Set<InferenceCapability>)
}

public struct StructuredInferenceRequest: Sendable {
    public var request: InferenceRequest
    public var jsonSchema: String
    public var requiredCapabilities: Set<InferenceCapability>
    public var maximumOutputBytes: Int
    public var maximumOutputTokens: Int
    public var timeBudget: Duration
    public var maximumRetries: Int
    public var fallbackPolicy: InferenceFallbackPolicy
    public var evidenceDigests: [String]

    public init(
        request: InferenceRequest,
        jsonSchema: String,
        requiredCapabilities: Set<InferenceCapability> = [.structuredJSON, .boundedPlanning],
        maximumOutputBytes: Int = 256_000,
        maximumOutputTokens: Int = 16_384,
        timeBudget: Duration = .seconds(30),
        maximumRetries: Int = 1,
        fallbackPolicy: InferenceFallbackPolicy = .require([.structuredJSON, .boundedPlanning]),
        evidenceDigests: [String] = []
    ) {
        self.request = request
        self.jsonSchema = jsonSchema
        self.requiredCapabilities = requiredCapabilities
        self.maximumOutputBytes = min(max(maximumOutputBytes, 1), 1_048_576)
        self.maximumOutputTokens = min(max(maximumOutputTokens, 1), 65_536)
        self.timeBudget = timeBudget
        self.maximumRetries = min(max(maximumRetries, 0), 2)
        self.fallbackPolicy = fallbackPolicy
        self.evidenceDigests = Array(evidenceDigests.prefix(24))
    }
}

public struct StructuredInferenceUsage: Codable, Equatable, Sendable {
    public var inputBytes: Int
    public var outputBytes: Int
    public var estimatedInputTokens: Int
    public var estimatedOutputTokens: Int
}

public struct StructuredInferenceRetryInfo: Codable, Equatable, Sendable {
    public var attempts: Int
    public var retries: Int
}

public struct StructuredInferenceProvenance: Codable, Equatable, Sendable {
    public var selectedMode: InferenceMode
    public var evidenceDigests: [String]
    public var requiredCapabilities: [InferenceCapability]
    public var measuredAt: Date
}

public struct StructuredInferenceResponse: Sendable {
    public var json: Data
    public var mode: InferenceMode
    public var rawProviderIdentity: String
    public var capabilities: Set<InferenceCapability>
    public var retryCount: Int
    public var usage: StructuredInferenceUsage
    public var provenance: StructuredInferenceProvenance
    public var retryInfo: StructuredInferenceRetryInfo
}

public enum InferenceError: Error, LocalizedError, Equatable {
    case providerUnavailable(InferenceMode)
    case remoteEndpointNotConfigured
    case remoteRequestFailed(statusCode: Int?, underlying: String)
    case onDeviceUnavailable(String)
    case onDeviceRequestFailed(String)
    case decodingFailed(String)
    case providerUnqualified(mode: InferenceMode, required: Set<InferenceCapability>)
    case structuredOutputInvalid(String)
    case timeBudgetExceeded

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
        case .providerUnqualified(let mode, let required):
            return "Inference mode \(mode.rawValue) lacks required capabilities: \(required.map(\.rawValue).sorted().joined(separator: ", "))."
        case .structuredOutputInvalid(let detail):
            return "Structured inference output is invalid: \(detail)"
        case .timeBudgetExceeded:
            return "Structured inference exceeded its time budget."
        }
    }
}

public protocol InferenceProvider: Sendable {
    var mode: InferenceMode { get }
    var capabilities: Set<InferenceCapability> { get }
    var identity: String { get }
    func generate(_ request: InferenceRequest) async throws -> InferenceResult
}


public extension InferenceProvider {
    var capabilities: Set<InferenceCapability> { [.text] }
    var identity: String { mode.rawValue }
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
    private let providerOverrides: [InferenceMode: any InferenceProvider]

    public init(
        eventBus: EventBus,
        metrics: EngineMetrics,
        currentMode: @escaping @Sendable () -> InferenceMode,
        remoteEndpoint: @escaping @Sendable () -> String,
        remoteModel: @escaping @Sendable () -> String = { "abbey-remote" },
        remoteAPIToken: @escaping @Sendable () -> String = { "" },
        providerOverrides: [InferenceMode: any InferenceProvider] = [:]
    ) {
        self.deterministicFloor = DeterministicFloorProvider()
        self.onDevice = FoundationModelsProvider()
        self.remote = RemoteOpenAICompatibleProvider(
            endpointProvider: remoteEndpoint,
            modelProvider: remoteModel,
            bearerTokenProvider: remoteAPIToken
        )
        self.eventBus = eventBus
        self.metrics = metrics
        self.currentMode = currentMode
        self.remoteEndpoint = remoteEndpoint
        self.providerOverrides = providerOverrides
    }

    public func generate(_ request: InferenceRequest) async -> InferenceResult {
        let mode = currentMode()
        let provider: any InferenceProvider = providerOverrides[mode] ?? {
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


    public func generateStructured(_ structured: StructuredInferenceRequest) async throws -> StructuredInferenceResponse {
        try Task.checkCancellation()
        let mode = currentMode()
        let provider: any InferenceProvider = providerOverrides[mode] ?? {
            switch mode {
            case .deterministicFloor: return deterministicFloor
            case .onDevice: return onDevice
            case .remoteCompatible: return remote
            }
        }()
        guard provider.capabilities.isSuperset(of: structured.requiredCapabilities) else {
            throw InferenceError.providerUnqualified(mode: mode, required: structured.requiredCapabilities)
        }
        if case .require(let policyCapabilities) = structured.fallbackPolicy,
           !provider.capabilities.isSuperset(of: policyCapabilities) {
            throw InferenceError.providerUnqualified(mode: mode, required: policyCapabilities)
        }
        guard (2...65_536).contains(structured.jsonSchema.utf8.count) else {
            throw InferenceError.structuredOutputInvalid("schema byte budget is invalid")
        }
        guard structured.evidenceDigests.allSatisfy(Self.isRevisionDigest) else {
            throw InferenceError.structuredOutputInvalid("evidence digests must be immutable lowercase revisions")
        }
        var request = structured.request
        request.systemPrompt += "\nReturn only JSON matching this schema:\n\(structured.jsonSchema)"
        let inputBytes = request.systemPrompt.utf8.count + request.userText.utf8.count
            + request.contextLines.reduce(0) { $0 + $1.utf8.count }
        guard inputBytes <= 2 * 1_024 * 1_024 else {
            throw InferenceError.structuredOutputInvalid("request exceeded input byte budget")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: structured.timeBudget)
        var lastError: Error = InferenceError.structuredOutputInvalid("provider returned no output")
        for retry in 0...structured.maximumRetries {
            do {
                try Task.checkCancellation()
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw InferenceError.timeBudgetExceeded }
                let result = try await Self.generate(provider: provider, request: request, timeout: remaining)
                try Task.checkCancellation()
                let normalized = Self.extractJSONObject(from: result.text)
                let data = Data(normalized.utf8)
                let tokenByteLimit = structured.maximumOutputTokens * 6
                guard data.count <= min(structured.maximumOutputBytes, tokenByteLimit) else {
                    throw InferenceError.structuredOutputInvalid("response exceeded byte/token budget")
                }
                let object = try JSONSerialization.jsonObject(with: data)
                try Self.validateStructuredOutput(object: object, schema: structured.jsonSchema)
                guard clock.now < deadline else { throw InferenceError.timeBudgetExceeded }
                metrics.recordInferenceCall(mode: mode, succeeded: true)
                let usage = StructuredInferenceUsage(
                    inputBytes: inputBytes,
                    outputBytes: data.count,
                    estimatedInputTokens: max((inputBytes + 3) / 4, 1),
                    estimatedOutputTokens: max((data.count + 3) / 4, 1)
                )
                return StructuredInferenceResponse(
                    json: data,
                    mode: mode,
                    rawProviderIdentity: provider.identity,
                    capabilities: provider.capabilities,
                    retryCount: retry,
                    usage: usage,
                    provenance: .init(
                        selectedMode: mode,
                        evidenceDigests: structured.evidenceDigests,
                        requiredCapabilities: structured.requiredCapabilities.sorted { $0.rawValue < $1.rawValue },
                        measuredAt: Date()
                    ),
                    retryInfo: .init(attempts: retry + 1, retries: retry)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
                if retry < structured.maximumRetries {
                    request.systemPrompt += "\nThe prior response was rejected. Return one complete JSON value only."
                }
            }
        }
        metrics.recordInferenceCall(mode: mode, succeeded: false)
        let mapped = (lastError as? InferenceError) ?? InferenceError.structuredOutputInvalid(lastError.localizedDescription)
        await eventBus.publish(.inferenceProviderFailed(mode: mode, message: mapped.localizedDescription))
        throw mapped
    }

    private nonisolated static func generate(
        provider: any InferenceProvider,
        request: InferenceRequest,
        timeout: Duration
    ) async throws -> InferenceResult {
        guard timeout > .zero else { throw InferenceError.timeBudgetExceeded }
        let race = StructuredInferenceRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let providerTask = Task<Void, Never> {
                    do { race.finish(.success(try await provider.generate(request))) }
                    catch { race.finish(.failure(error)) }
                }
                let timeoutTask = Task<Void, Never> {
                    do {
                        try await Task.sleep(for: timeout)
                        race.finish(.failure(InferenceError.timeBudgetExceeded))
                    } catch is CancellationError {
                        return
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                race.install(providerTask: providerTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    private nonisolated static func validateStructuredOutput(object: Any, schema: String) throws {
        guard let schemaData = schema.data(using: .utf8),
              let schemaObject = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        else { throw InferenceError.structuredOutputInvalid("schema is not a JSON object") }
        var remainingNodes = 20_000
        try validate(value: object, against: schemaObject, path: "$", depth: 0, remainingNodes: &remainingNodes)
    }

    private nonisolated static func validate(
        value: Any,
        against schema: [String: Any],
        path: String,
        depth: Int,
        remainingNodes: inout Int
    ) throws {
        guard depth <= 32, remainingNodes > 0 else {
            throw InferenceError.structuredOutputInvalid("schema validation complexity exceeded")
        }
        remainingNodes -= 1
        let supported: Set<String> = [
            "$schema", "title", "description", "type", "required", "properties",
            "items", "minItems", "maxItems", "minLength", "maxLength",
            "minimum", "maximum", "enum", "additionalProperties",
        ]
        let unsupported = Set(schema.keys).subtracting(supported)
        guard unsupported.isEmpty else {
            throw InferenceError.structuredOutputInvalid(
                "schema uses unsupported keywords: \(unsupported.sorted().joined(separator: ", "))"
            )
        }

        if let rawType = schema["type"] {
            guard let type = rawType as? String else {
                throw InferenceError.structuredOutputInvalid("schema type at \(path) is invalid")
            }
            let matches: Bool
            switch type {
            case "object": matches = value is [String: Any]
            case "array": matches = value is [Any]
            case "string": matches = value is String
            case "boolean": matches = (value as? NSNumber).map(isJSONBoolean) ?? false
            case "number":
                matches = (value as? NSNumber).map { !isJSONBoolean($0) } ?? false
            case "integer":
                matches = (value as? NSNumber).map {
                    !isJSONBoolean($0) && $0.doubleValue.isFinite
                        && $0.doubleValue.rounded(.towardZero) == $0.doubleValue
                } ?? false
            case "null": matches = value is NSNull
            default:
                throw InferenceError.structuredOutputInvalid("schema type at \(path) is unsupported")
            }
            guard matches else {
                throw InferenceError.structuredOutputInvalid("value at \(path) does not match type \(type)")
            }
        }

        if let rawEnum = schema["enum"] {
            guard let choices = rawEnum as? [Any], !choices.isEmpty else {
                throw InferenceError.structuredOutputInvalid("schema enum at \(path) is invalid")
            }
            guard choices.contains(where: { jsonValuesEqual(value, $0) }) else {
                throw InferenceError.structuredOutputInvalid("value at \(path) is outside its enum")
            }
        }

        if let dictionary = value as? [String: Any] {
            let required: [String]
            if let rawRequired = schema["required"] {
                guard let decoded = rawRequired as? [String] else {
                    throw InferenceError.structuredOutputInvalid("schema required list at \(path) is invalid")
                }
                required = decoded
            } else { required = [] }
            let missing = required.filter { dictionary[$0] == nil }
            guard missing.isEmpty else {
                throw InferenceError.structuredOutputInvalid(
                    "missing required properties at \(path): \(missing.sorted().joined(separator: ", "))"
                )
            }
            let properties: [String: Any]
            if let rawProperties = schema["properties"] {
                guard let decoded = rawProperties as? [String: Any] else {
                    throw InferenceError.structuredOutputInvalid("schema properties at \(path) are invalid")
                }
                properties = decoded
            } else { properties = [:] }
            if let rawAdditional = schema["additionalProperties"] {
                guard let additional = rawAdditional as? Bool else {
                    throw InferenceError.structuredOutputInvalid("additionalProperties at \(path) is invalid")
                }
                if !additional {
                    let extras = Set(dictionary.keys).subtracting(properties.keys)
                    guard extras.isEmpty else {
                        throw InferenceError.structuredOutputInvalid(
                            "unexpected properties at \(path): \(extras.sorted().joined(separator: ", "))"
                        )
                    }
                }
            }
            for (key, child) in dictionary {
                guard let rawChildSchema = properties[key] else { continue }
                guard let childSchema = rawChildSchema as? [String: Any] else {
                    throw InferenceError.structuredOutputInvalid("property schema at \(path).\(key) is invalid")
                }
                try validate(
                    value: child,
                    against: childSchema,
                    path: "\(path).\(key)",
                    depth: depth + 1,
                    remainingNodes: &remainingNodes
                )
            }
        }

        if let array = value as? [Any] {
            let minimum = try schemaInteger(schema["minItems"], label: "minItems", path: path)
            let maximum = try schemaInteger(schema["maxItems"], label: "maxItems", path: path)
            if let minimum, array.count < minimum {
                throw InferenceError.structuredOutputInvalid("array at \(path) is shorter than minItems")
            }
            if let maximum, array.count > maximum {
                throw InferenceError.structuredOutputInvalid("array at \(path) exceeds maxItems")
            }
            if let rawItems = schema["items"] {
                guard let itemSchema = rawItems as? [String: Any] else {
                    throw InferenceError.structuredOutputInvalid("item schema at \(path) is invalid")
                }
                for (index, child) in array.enumerated() {
                    try validate(
                        value: child,
                        against: itemSchema,
                        path: "\(path)[\(index)]",
                        depth: depth + 1,
                        remainingNodes: &remainingNodes
                    )
                }
            }
        }

        if let string = value as? String {
            let minimum = try schemaInteger(schema["minLength"], label: "minLength", path: path)
            let maximum = try schemaInteger(schema["maxLength"], label: "maxLength", path: path)
            if let minimum, string.count < minimum {
                throw InferenceError.structuredOutputInvalid("string at \(path) is shorter than minLength")
            }
            if let maximum, string.count > maximum {
                throw InferenceError.structuredOutputInvalid("string at \(path) exceeds maxLength")
            }
        }

        if let number = value as? NSNumber, !isJSONBoolean(number) {
            if let minimum = schema["minimum"] as? NSNumber, number.doubleValue < minimum.doubleValue {
                throw InferenceError.structuredOutputInvalid("number at \(path) is below minimum")
            }
            if let maximum = schema["maximum"] as? NSNumber, number.doubleValue > maximum.doubleValue {
                throw InferenceError.structuredOutputInvalid("number at \(path) exceeds maximum")
            }
        }
    }

    private nonisolated static func schemaInteger(
        _ value: Any?,
        label: String,
        path: String
    ) throws -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber,
              !isJSONBoolean(number),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.intValue >= 0
        else { throw InferenceError.structuredOutputInvalid("\(label) at \(path) is invalid") }
        return number.intValue
    }

    private nonisolated static func isJSONBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private nonisolated static func jsonValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        jsonValuesEqual(lhs, rhs, depth: 0)
    }

    private nonisolated static func jsonValuesEqual(
        _ lhs: Any,
        _ rhs: Any,
        depth: Int
    ) -> Bool {
        guard depth <= 32 else { return false }
        if lhs is NSNull || rhs is NSNull { return lhs is NSNull && rhs is NSNull }
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
            let leftIsBoolean = isJSONBoolean(left)
            let rightIsBoolean = isJSONBoolean(right)
            guard leftIsBoolean == rightIsBoolean else { return false }
            return left.isEqual(to: right)
        }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy {
                jsonValuesEqual($0.0, $0.1, depth: depth + 1)
            }
        }
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            guard left.keys == right.keys else { return false }
            return left.allSatisfy { key, value in
                right[key].map { jsonValuesEqual(value, $0, depth: depth + 1) } ?? false
            }
        }
        return false
    }

    private nonisolated static func isRevisionDigest(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private nonisolated static func extractJSONObject(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 3 else { return trimmed }
        let opener = lines[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let closer = lines[lines.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard (opener == "```" || opener == "```json"), closer == "```" else {
            return trimmed
        }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }
}

private final class StructuredInferenceRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<InferenceResult, any Error>?
    private var pendingResult: Result<InferenceResult, any Error>?
    private var providerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<InferenceResult, any Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func install(providerTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            providerTask.cancel()
            timeoutTask.cancel()
        } else {
            self.providerTask = providerTask
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    func finish(_ result: Result<InferenceResult, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        let providerTask = self.providerTask
        let timeoutTask = self.timeoutTask
        self.providerTask = nil
        self.timeoutTask = nil
        lock.unlock()

        providerTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
