import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport boundary for Abbey sync traffic.
///
/// Sync requests can carry user-authored content and an API bearer token. Plain HTTP is
/// therefore limited to exact loopback hosts for local development; every other host must
/// use HTTPS.
public enum SyncTransportPolicy: Sendable {
    public enum PolicyError: Error, LocalizedError, Equatable, Sendable {
        case invalidURL
        case unsupportedScheme
        case insecureNonLoopbackHost(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "sync URL must be an absolute HTTP(S) URL with a host"
            case .unsupportedScheme:
                return "sync URL scheme must be http or https"
            case .insecureNonLoopbackHost(let host):
                return "plain HTTP sync is allowed only for localhost, 127.0.0.1, or ::1; use HTTPS for \(host)"
            }
        }
    }

    /// Validate and normalize a sync base URL before a request receives content or credentials.
    @discardableResult
    public static func validate(baseURL rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              !rawHost.isEmpty,
              let url = components.url
        else {
            throw PolicyError.invalidURL
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw PolicyError.unsupportedScheme
        }

        if scheme == "http" {
            let host = normalizedHost(rawHost)
            guard exactLoopbackHosts.contains(host) else {
                throw PolicyError.insecureNonLoopbackHost(rawHost)
            }
        }

        return url
    }

    /// Build a sync request against a validated base URL: validate the transport, strip a
    /// trailing slash, join path + query, and attach an optional Bearer token. The single
    /// request-building boundary for every sync client, so the validate-before-credentials
    /// guarantee cannot drift between call sites.
    public static func makeRequest(
        baseURL: String,
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        bearerToken: String? = nil
    ) throws -> URLRequest {
        let validatedBase = try validate(baseURL: baseURL).absoluteString
        let base = validatedBase.hasSuffix("/") ? String(validatedBase.dropLast()) : validatedBase
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: base + suffix) else {
            throw PolicyError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw PolicyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static let exactLoopbackHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "::1",
    ]

    private static func normalizedHost(_ host: String) -> String {
        let lowercased = host.lowercased()
        if lowercased.hasPrefix("["), lowercased.hasSuffix("]") {
            return String(lowercased.dropFirst().dropLast())
        }
        return lowercased
    }
}
