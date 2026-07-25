import AbbeyServerKit
import Foundation
import Testing
import Vapor

@Suite("Twitch EventSub auto-subscribe")
struct TwitchEventSubAutoSubscriberTests {
    private static let fullEnvironment: [String: String] = [
        "ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE": "1",
        "TWITCH_CLIENT_ID": "cid",
        "TWITCH_CLIENT_SECRET": "csecret",
        "TWITCH_EVENTSUB_SECRET": "whsecret",
        "TWITCH_EVENTSUB_CALLBACK_URL": "https://abbey.example/api/twitch/eventsub",
        "TWITCH_BROADCASTER_USER_ID": "100",
        "TWITCH_BOT_USER_ID": "200"
    ]

    @Test func disabledWhenFlagUnset() {
        var env = Self.fullEnvironment
        env.removeValue(forKey: "ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE")
        #expect(TwitchEventSubAutoSubscriber.decide(environment: env) == .disabled)
    }

    @Test func disabledWhenFlagIsZero() {
        var env = Self.fullEnvironment
        env["ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE"] = "0"
        #expect(TwitchEventSubAutoSubscriber.decide(environment: env) == .disabled)
    }

    @Test func missingEnvironmentListsAbsentNamesSorted() {
        var env = Self.fullEnvironment
        env.removeValue(forKey: "TWITCH_CLIENT_SECRET")
        env["TWITCH_BOT_USER_ID"] = "   "
        #expect(TwitchEventSubAutoSubscriber.decide(environment: env)
            == .missingEnvironment(["TWITCH_BOT_USER_ID", "TWITCH_CLIENT_SECRET"]))
    }

    @Test func rejectsNonHTTPSCallback() {
        var env = Self.fullEnvironment
        env["TWITCH_EVENTSUB_CALLBACK_URL"] = "http://abbey.example/api/twitch/eventsub"
        #expect(TwitchEventSubAutoSubscriber.decide(environment: env)
            == .invalidCallbackURL("http://abbey.example/api/twitch/eventsub"))
    }

    @Test func readyCarriesFullConfig() {
        #expect(TwitchEventSubAutoSubscriber.decide(environment: Self.fullEnvironment)
            == .ready(TwitchEventSubAutoSubscriber.Config(
                clientId: "cid",
                clientSecret: "csecret",
                callbackURL: "https://abbey.example/api/twitch/eventsub",
                webhookSecret: "whsecret",
                broadcasterUserId: "100",
                botUserId: "200"
            )))
    }

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

    private func jsonResponse(_ status: HTTPStatus, _ json: String, on app: Application) -> ClientResponse {
        var buffer = app.client.byteBufferAllocator.buffer(capacity: json.utf8.count)
        buffer.writeString(json)
        var headers = HTTPHeaders()
        headers.contentType = .json
        return ClientResponse(status: status, headers: headers, body: buffer)
    }

    @Test func subscribesChatAndStreamLifecycleTypes() async throws {
        try await withApp { app in
            let fake = QueuedClient(
                eventLoop: app.eventLoopGroup.next(),
                responses: [
                    jsonResponse(.ok, #"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#, on: app),
                    ClientResponse(status: .accepted),
                    ClientResponse(status: .accepted),
                    ClientResponse(status: .accepted)
                ]
            )

            let subscribed = await TwitchEventSubAutoSubscriber.subscribeIfConfigured(
                app: app,
                client: fake,
                environment: Self.fullEnvironment
            )

            #expect(subscribed)
            // 1 token + 3 subscriptions
            #expect(fake.requests.count == 4)

            let types = try fake.requests.dropFirst().map { request -> String in
                let bodyData = request.body.map { Data($0.readableBytesView) } ?? Data()
                let decoded = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                return decoded?["type"] as? String ?? ""
            }
            #expect(types == [
                "channel.chat.message",
                "stream.online",
                "stream.offline"
            ])

            let chatBody = fake.requests[1].body.map { Data($0.readableBytesView) } ?? Data()
            let chatDecoded = try JSONSerialization.jsonObject(with: chatBody) as? [String: Any]
            let chatCondition = chatDecoded?["condition"] as? [String: String]
            #expect(chatCondition?["broadcaster_user_id"] == "100")
            #expect(chatCondition?["user_id"] == "200")

            let onlineBody = fake.requests[2].body.map { Data($0.readableBytesView) } ?? Data()
            let onlineDecoded = try JSONSerialization.jsonObject(with: onlineBody) as? [String: Any]
            let onlineCondition = onlineDecoded?["condition"] as? [String: String]
            #expect(onlineCondition?["broadcaster_user_id"] == "100")
            #expect(onlineCondition?["user_id"] == nil)

            let transport = onlineDecoded?["transport"] as? [String: String]
            #expect(transport?["callback"] == "https://abbey.example/api/twitch/eventsub")
            #expect(transport?["secret"] == "whsecret")
        }
    }

    @Test func helixFailureLogsAndReturnsFalseWithoutThrowing() async throws {
        try await withApp { app in
            let fake = QueuedClient(
                eventLoop: app.eventLoopGroup.next(),
                responses: [jsonResponse(.unauthorized, #"{"message":"invalid client"}"#, on: app)]
            )

            let subscribed = await TwitchEventSubAutoSubscriber.subscribeIfConfigured(
                app: app,
                client: fake,
                environment: Self.fullEnvironment
            )

            #expect(!subscribed)
        }
    }

    @Test func disabledFlagMakesNoHelixCalls() async throws {
        try await withApp { app in
            let fake = QueuedClient(eventLoop: app.eventLoopGroup.next(), responses: [])
            var env = Self.fullEnvironment
            env["ABBEY_TWITCH_EVENTSUB_AUTO_SUBSCRIBE"] = "0"

            let subscribed = await TwitchEventSubAutoSubscriber.subscribeIfConfigured(
                app: app,
                client: fake,
                environment: env
            )

            #expect(!subscribed)
            #expect(fake.requests.isEmpty)
        }
    }
}

private final class QueuedClient: Client, @unchecked Sendable {
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
            return eventLoop.makeFailedFuture(QueuedClientError.noResponseQueued)
        }
        return eventLoop.makeSucceededFuture(responses.removeFirst())
    }
}

private enum QueuedClientError: Error {
    case noResponseQueued
}
