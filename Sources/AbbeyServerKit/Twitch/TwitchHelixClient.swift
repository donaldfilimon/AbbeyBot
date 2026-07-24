import Vapor

/// Minimal client for the pieces of Twitch's Helix API the EventSub subscribe flow needs: an
/// app access token (client credentials grant) and webhook subscription creation.
///
/// Request construction and response parsing are unit-tested against a fake `Client` (see
/// `TwitchHelixClientTests`) — that verifies this code builds the right HTTP calls. It does
/// NOT verify Twitch's real API accepts them, and it cannot exercise the
/// `webhook_callback_verification` round trip Twitch performs against the callback URL, since
/// that requires a live, publicly reachable deployment this environment doesn't have. Treat
/// this as untested-in-production until run against a real deployment with real credentials.
public struct TwitchHelixClient: Sendable {
    public enum ClientError: Error, LocalizedError, Sendable {
        case tokenRequestFailed(status: UInt, body: String)
        case subscriptionRequestFailed(status: UInt, body: String)

        public var errorDescription: String? {
            switch self {
            case let .tokenRequestFailed(status, body):
                return "Twitch app-token request failed (status \(status)): \(body)"
            case let .subscriptionRequestFailed(status, body):
                return "Twitch EventSub subscription request failed (status \(status)): \(body)"
            }
        }
    }

    private let client: any Client
    private let clientId: String
    private let clientSecret: String

    public init(client: any Client, clientId: String, clientSecret: String) {
        self.client = client
        self.clientId = clientId
        self.clientSecret = clientSecret
    }

    /// Client Credentials Grant.
    /// https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#client-credentials-grant-flow
    public func fetchAppAccessToken() async throws -> String {
        let response = try await client.post("https://id.twitch.tv/oauth2/token") { req in
            try req.content.encode(
                AppTokenRequestBody(clientId: clientId, clientSecret: clientSecret),
                as: .urlEncodedForm
            )
        }.get()
        guard response.status == .ok else {
            throw ClientError.tokenRequestFailed(status: response.status.code, body: Self.bodyString(response))
        }
        return try response.content.decode(AppTokenResponseBody.self).accessToken
    }

    /// Creates an EventSub webhook subscription.
    /// https://dev.twitch.tv/docs/api/reference/#create-eventsub-subscription
    public func createSubscription(
        type: String,
        version: String,
        condition: [String: String],
        callbackURL: String,
        webhookSecret: String,
        appAccessToken: String
    ) async throws {
        let response = try await client.post("https://api.twitch.tv/helix/eventsub/subscriptions") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: appAccessToken)
            req.headers.replaceOrAdd(name: "Client-Id", value: clientId)
            try req.content.encode(
                CreateSubscriptionBody(
                    type: type,
                    version: version,
                    condition: condition,
                    transport: .init(method: "webhook", callback: callbackURL, secret: webhookSecret)
                )
            )
        }.get()
        guard response.status == .accepted || response.status == .created else {
            throw ClientError.subscriptionRequestFailed(status: response.status.code, body: Self.bodyString(response))
        }
    }

    private static func bodyString(_ response: ClientResponse) -> String {
        guard var body = response.body else { return "" }
        return body.readString(length: body.readableBytes) ?? ""
    }
}

struct AppTokenRequestBody: Content {
    var clientId: String
    var clientSecret: String
    var grantType: String = "client_credentials"

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case grantType = "grant_type"
    }
}

struct AppTokenResponseBody: Content {
    var accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

struct CreateSubscriptionBody: Content {
    struct Transport: Content {
        var method: String
        var callback: String
        var secret: String
    }

    var type: String
    var version: String
    var condition: [String: String]
    var transport: Transport
}
