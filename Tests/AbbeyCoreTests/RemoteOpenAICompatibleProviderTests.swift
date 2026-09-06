import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AbbeyCore

@Suite("Remote OpenAI-compatible provider")
struct RemoteOpenAICompatibleProviderTests {
    @Test func reasoningModelsOmitUnsupportedTemperature() throws {
        let request = try RemoteOpenAICompatibleProvider.makeURLRequest(
            endpoint: "https://api.openai.com/v1/chat/completions",
            model: "gpt-5.4-mini",
            bearerToken: "",
            request: .init(systemPrompt: "system", userText: "hello")
        )
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["temperature"] == nil)
    }

    @Test func requestUsesConfiguredModelAndBearerWithoutChangingPromptBoundary() throws {
        let request = try RemoteOpenAICompatibleProvider.makeURLRequest(
            endpoint: "https://inference.example/v1/chat/completions",
            model: "provider/model-2026",
            bearerToken: "secret-provider-token",
            request: .init(
                systemPrompt: "Follow the operator request.",
                userText: "Build a site.",
                contextLines: ["reference only"]
            )
        )

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-provider-token")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "provider/model-2026")
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect((messages[0]["content"] as? String)?.contains("<untrusted_context>") == true)
        #expect((messages[1]["content"] as? String)?.contains("Build a site.") == true)
    }

    @Test func emptyModelAndBearerPreserveLocalCompatibleDefaults() throws {
        let request = try RemoteOpenAICompatibleProvider.makeURLRequest(
            endpoint: "http://127.0.0.1:11434/v1/chat/completions",
            model: "   ",
            bearerToken: "",
            request: .init(systemPrompt: "system", userText: "hello")
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "abbey-remote")
        #expect(object["temperature"] as? Double == 0.7)
    }

    @Test func redirectsStayOnTheExactOrigin() {
        let original = URL(string: "https://provider.example/v1/chat/completions")!
        #expect(RemoteOpenAICompatibleProvider.redirectIsSafe(
            from: original,
            to: URL(string: "https://provider.example/v2/chat/completions")!
        ))
        #expect(RemoteOpenAICompatibleProvider.redirectIsSafe(
            from: URL(string: "https://provider.example:443/v1/chat/completions")!,
            to: URL(string: "https://provider.example/v2/chat/completions")!
        ))
        #expect(!RemoteOpenAICompatibleProvider.redirectIsSafe(
            from: original,
            to: URL(string: "http://provider.example/v2/chat/completions")!
        ))
        #expect(!RemoteOpenAICompatibleProvider.redirectIsSafe(
            from: original,
            to: URL(string: "https://redirect.example/v2/chat/completions")!
        ))
        #expect(!RemoteOpenAICompatibleProvider.redirectIsSafe(
            from: original,
            to: URL(string: "https://provider.example:8443/v2/chat/completions")!
        ))
    }

    @Test func nonSuccessResponseDoesNotExposeProviderBody() async {
        let secret = "provider-body-secret"
        let provider = RemoteOpenAICompatibleProvider(
            endpointProvider: { "https://example.invalid/v1/chat/completions" },
            transport: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://example.invalid/v1/chat/completions")!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(secret.utf8), response)
            }
        )

        do {
            _ = try await provider.generate(.init(systemPrompt: "system", userText: "hello"))
            Issue.record("Expected the provider to reject a non-success response")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("401"))
            #expect(message.contains("body redacted"))
            #expect(!message.contains(secret))
        }
    }

    @Test func transportFailureDoesNotExposeEndpointOrCredential() async {
        let endpointSecret = "endpoint-query-secret"
        let credential = "bearer-secret"
        let provider = RemoteOpenAICompatibleProvider(
            endpointProvider: { "https://example.invalid/v1/chat/completions?token=\(endpointSecret)" },
            modelProvider: { "hosted-model" },
            bearerTokenProvider: { credential },
            transport: { _ in
                throw URLError(.cannotConnectToHost, userInfo: [
                    NSURLErrorFailingURLErrorKey: URL(
                        string: "https://example.invalid/?token=\(endpointSecret)"
                    )!,
                    NSLocalizedDescriptionKey: "Authorization: Bearer \(credential)",
                ])
            }
        )

        do {
            _ = try await provider.generate(.init(systemPrompt: "system", userText: "hello"))
            Issue.record("Expected the provider transport to fail")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("transport failed; details redacted"))
            #expect(!message.contains(endpointSecret))
            #expect(!message.contains(credential))
        }
    }
}
