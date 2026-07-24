import Foundation

/// Talks to any OpenAI-compatible `/chat/completions` endpoint over URLSession — no
/// vendor SDK dependency, matching the stdlib-first / minimal-dependency preference.
/// Works against local inference servers (llama.cpp server, LM Studio, Ollama's OpenAI
/// shim, vLLM) as well as hosted OpenAI-compatible APIs.
public struct RemoteOpenAICompatibleProvider: InferenceProvider {
    public let mode: InferenceMode = .remoteCompatible

    private let endpointProvider: @Sendable () -> String
    private let session: URLSession

    public init(endpointProvider: @escaping @Sendable () -> String, session: URLSession = .shared) {
        self.endpointProvider = endpointProvider
        self.session = session
    }

    public func generate(_ request: InferenceRequest) async throws -> InferenceResult {
        let endpointString = endpointProvider()
        guard !endpointString.isEmpty, let url = URL(string: endpointString) else {
            throw InferenceError.remoteEndpointNotConfigured
        }

        var messages: [ChatMessage] = [ChatMessage(role: "system", content: request.systemPrompt)]
        messages.append(contentsOf: request.contextLines.map { ChatMessage(role: "system", content: $0) })
        messages.append(ChatMessage(role: "user", content: request.userText))

        let body = ChatCompletionRequest(model: "abbey-remote", messages: messages, temperature: 0.7)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw InferenceError.remoteRequestFailed(statusCode: statusCode, underlying: bodyText)
        }

        do {
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let text = decoded.choices.first?.message.content else {
                throw InferenceError.decodingFailed("no choices in response")
            }
            return InferenceResult(text: text, mode: .remoteCompatible)
        } catch let decodingError as DecodingError {
            throw InferenceError.decodingFailed(briefDecodingError(decodingError))
        }
    }
}

private func briefDecodingError(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, let context):
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty
            ? "missing key '\(key.stringValue)'"
            : "missing key '\(key.stringValue)' at \(path)"
    case .typeMismatch(_, let context):
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "type mismatch" : "type mismatch at \(path)"
    case .valueNotFound(_, let context):
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "missing value" : "missing value at \(path)"
    case .dataCorrupted(let context):
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "corrupt response" : "corrupt response at \(path)"
    @unknown default:
        return error.localizedDescription
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatCompletionResponse: Codable {
    struct Choice: Codable {
        let message: ChatMessage
    }
    let choices: [Choice]
}
