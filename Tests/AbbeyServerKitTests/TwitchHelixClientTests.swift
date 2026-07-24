import AbbeyServerKit
import Foundation
import Testing
import Vapor

@Suite("Twitch Helix client")
struct TwitchHelixClientTests {
    private func withApp<T: Sendable>(_ body: @Sendable (Application) async throws -> T) async throws -> T {
        let app = try await Application.make(.testing)
        do {
            let result = try await body(app)
            try await app.asyncShutdown()
            return result
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func jsonResponse(_ status: HTTPStatus, _ json: String, allocator: ByteBufferAllocator) -> ClientResponse {
        var buffer = allocator.buffer(capacity: json.utf8.count)
        buffer.writeString(json)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return ClientResponse(status: status, headers: headers, body: buffer)
    }

    @Test func fetchAppAccessTokenSendsClientCredentialsRequestAndParsesToken() async throws {
        try await withApp { app in
            let fake = CapturingClient(
                eventLoop: app.eventLoopGroup.next(),
                responses: [
                    jsonResponse(
                        .ok,
                        #"{"access_token":"tok123","expires_in":3600,"token_type":"bearer"}"#,
                        allocator: app.client.byteBufferAllocator
                    )
                ]
            )
            let subject = TwitchHelixClient(client: fake, clientId: "my-client-id", clientSecret: "my-client-secret")

            let token = try await subject.fetchAppAccessToken()

            #expect(token == "tok123")
            #expect(fake.requests.count == 1)
            let request = fake.requests[0]
            #expect(request.method == .POST)
            #expect(request.url.string == "https://id.twitch.tv/oauth2/token")
            let bodyString = request.body.map { String(buffer: $0) } ?? ""
            #expect(bodyString.contains("client_id=my-client-id"))
            #expect(bodyString.contains("client_secret=my-client-secret"))
            #expect(bodyString.contains("grant_type=client_credentials"))
        }
    }

    @Test func fetchAppAccessTokenThrowsOnNonOKStatus() async throws {
        try await withApp { app in
            let fake = CapturingClient(
                eventLoop: app.eventLoopGroup.next(),
                responses: [
                    jsonResponse(.unauthorized, #"{"message":"invalid client"}"#, allocator: app.client.byteBufferAllocator)
                ]
            )
            let subject = TwitchHelixClient(client: fake, clientId: "id", clientSecret: "secret")

            await #expect(throws: TwitchHelixClient.ClientError.self) {
                _ = try await subject.fetchAppAccessToken()
            }
        }
    }

    @Test func createSubscriptionSendsAuthorizedRequestWithExpectedBody() async throws {
        try await withApp { app in
            let fake = CapturingClient(
                eventLoop: app.eventLoopGroup.next(),
                responses: [ClientResponse(status: .accepted)]
            )
            let subject = TwitchHelixClient(client: fake, clientId: "my-client-id", clientSecret: "my-client-secret")

            try await subject.createSubscription(
                type: "channel.follow",
                version: "2",
                condition: ["broadcaster_user_id": "12345", "moderator_user_id": "12345"],
                callbackURL: "https://example.com/api/twitch/eventsub",
                webhookSecret: "whsecret",
                appAccessToken: "app-token-abc"
            )

            #expect(fake.requests.count == 1)
            let request = fake.requests[0]
            #expect(request.method == .POST)
            #expect(request.url.string == "https://api.twitch.tv/helix/eventsub/subscriptions")
            #expect(request.headers.bearerAuthorization?.token == "app-token-abc")
            #expect(request.headers.first(name: "Client-Id") == "my-client-id")

            let bodyData = request.body.map { Data($0.readableBytesView) } ?? Data()
            let decoded = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(decoded?["type"] as? String == "channel.follow")
            #expect(decoded?["version"] as? String == "2")
            let condition = decoded?["condition"] as? [String: String]
            #expect(condition?["broadcaster_user_id"] == "12345")
            let transport = decoded?["transport"] as? [String: String]
            #expect(transport?["method"] == "webhook")
            #expect(transport?["callback"] == "https://example.com/api/twitch/eventsub")
            #expect(transport?["secret"] == "whsecret")
        }
    }

    @Test func createSubscriptionThrowsOnFailureStatus() async throws {
        try await withApp { app in
            let fake = CapturingClient(
                eventLoop: app.eventLoopGroup.next(),
                responses: [jsonResponse(.badRequest, #"{"message":"bad condition"}"#, allocator: app.client.byteBufferAllocator)]
            )
            let subject = TwitchHelixClient(client: fake, clientId: "id", clientSecret: "secret")

            await #expect(throws: TwitchHelixClient.ClientError.self) {
                try await subject.createSubscription(
                    type: "channel.follow",
                    version: "2",
                    condition: [:],
                    callbackURL: "https://example.com/api/twitch/eventsub",
                    webhookSecret: "whsecret",
                    appAccessToken: "app-token-abc"
                )
            }
        }
    }
}

private final class CapturingClient: Client, @unchecked Sendable {
    let eventLoop: EventLoop
    private(set) var requests: [ClientRequest] = []
    private var responses: [ClientResponse]

    init(eventLoop: EventLoop, responses: [ClientResponse]) {
        self.eventLoop = eventLoop
        self.responses = responses
    }

    func delegating(to eventLoop: EventLoop) -> Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        requests.append(request)
        guard !responses.isEmpty else {
            return eventLoop.makeFailedFuture(CapturingClientError.noResponseQueued)
        }
        return eventLoop.makeSucceededFuture(responses.removeFirst())
    }
}

private enum CapturingClientError: Error {
    case noResponseQueued
}
