import Foundation

public struct QuasarPreviewTicket: Codable, Equatable, Sendable {
    public var url: String
    public var expiresAt: Date

    public init(url: String, expiresAt: Date) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

public struct QuasarActivePreview: Codable, Equatable, Sendable {
    public var siteID: String
    public var generation: String
    public var port: Int

    public init(siteID: String, generation: String, port: Int) {
        self.siteID = siteID
        self.generation = generation
        self.port = port
    }
}

/// Returned only to the internal ticket redemption route. `setCookie` is a
/// complete host-only cookie field value and deliberately has no Domain attribute.
public struct QuasarPreviewCookieGrant: Equatable, Sendable {
    public var setCookie: String
    public var redirectURL: String
    public var expiresAt: Date

    public init(setCookie: String, redirectURL: String, expiresAt: Date) {
        self.setCookie = setCookie
        self.redirectURL = redirectURL
        self.expiresAt = expiresAt
    }
}

/// A successful Caddy authorization decision. Only the service-owned loopback
/// upstream is exposed; the caller never supplies or selects a port.
public struct QuasarPreviewAuthorization: Codable, Equatable, Sendable {
    public var siteID: String
    public var generation: String
    public var upstream: String

    public init(siteID: String, generation: String, upstream: String) {
        self.siteID = siteID
        self.generation = generation
        self.upstream = upstream
    }
}

public actor QuasarPreviewAccessController {
    public static let cookieName = "__Host-abbey-quasar-preview"

    private struct TicketRecord: Sendable {
        var active: QuasarActivePreview
        var host: String
        var expiresAt: Date
    }

    private struct SessionRecord: Sendable {
        var active: QuasarActivePreview
        var host: String
        var expiresAt: Date
    }

    private let previewDomain: String
    private let upstreamHost: String
    private var active: QuasarActivePreview?
    private var tickets: [String: TicketRecord] = [:]
    private var sessions: [String: SessionRecord] = [:]

    public init(
        previewDomain: String = ProcessInfo.processInfo.environment["ABBEY_QUASAR_PREVIEW_DOMAIN"]
            ?? "preview.xfoss.dev",
        upstreamHost: String = ProcessInfo.processInfo.environment["ABBEY_QUASAR_PREVIEW_UPSTREAM_HOST"]
            ?? "127.0.0.1"
    ) {
        self.previewDomain = Self.checkedDomain(previewDomain) ?? "preview.xfoss.dev"
        self.upstreamHost = Self.checkedUpstreamHost(upstreamHost) ?? "127.0.0.1"
    }

    /// Activating a preview retires all earlier tickets and cookies, including
    /// those for another site. The process manager enforces the same global limit.
    public func activate(_ preview: QuasarActivePreview) {
        guard Self.isSiteID(preview.siteID), Self.isGeneration(preview.generation),
              (1_024...65_535).contains(preview.port)
        else {
            active = nil
            tickets.removeAll(keepingCapacity: false)
            sessions.removeAll(keepingCapacity: false)
            return
        }
        active = preview
        tickets.removeAll(keepingCapacity: false)
        sessions.removeAll(keepingCapacity: false)
    }

    public func retire(siteID: String) {
        guard active?.siteID == siteID else { return }
        active = nil
        tickets.removeAll(keepingCapacity: false)
        sessions.removeAll(keepingCapacity: false)
    }

    public func retireAll() {
        active = nil
        tickets.removeAll(keepingCapacity: false)
        sessions.removeAll(keepingCapacity: false)
    }

    public func current() -> QuasarActivePreview? { active }

    public func issue(
        siteID: String,
        generation: String,
        now: Date = Date()
    ) throws -> QuasarPreviewTicket {
        cleanup(now: now)
        guard let current = active,
              current.siteID == siteID,
              current.generation == generation
        else { throw QuasarError.authorizationDenied("preview generation is not active") }
        let host = Self.host(siteID: siteID, domain: previewDomain)
        let token = Self.randomToken()
        let expiresAt = now.addingTimeInterval(60)
        tickets[token] = .init(active: current, host: host, expiresAt: expiresAt)
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/_quasar/preview-session"
        components.queryItems = [.init(name: "ticket", value: token)]
        guard let url = components.url?.absoluteString else {
            tickets[token] = nil
            throw QuasarError.processFailed("preview ticket URL could not be constructed")
        }
        return .init(url: url, expiresAt: expiresAt)
    }

    public func redeem(
        ticket token: String,
        host rawHost: String,
        now: Date = Date()
    ) throws -> QuasarPreviewCookieGrant {
        cleanup(now: now)
        guard let record = tickets.removeValue(forKey: token),
              record.expiresAt > now,
              let host = Self.checkedHost(rawHost),
              host == record.host,
              active == record.active
        else { throw QuasarError.authorizationDenied("preview ticket is invalid or expired") }
        let session = Self.randomToken()
        let expiresAt = now.addingTimeInterval(900)
        sessions[session] = .init(active: record.active, host: host, expiresAt: expiresAt)
        let cookie = "\(Self.cookieName)=\(session); Path=/; Max-Age=900; Secure; HttpOnly; SameSite=Lax"
        return .init(
            setCookie: cookie,
            redirectURL: "https://\(host)/",
            expiresAt: expiresAt
        )
    }

    public func authorize(
        host rawHost: String,
        cookieHeader: String,
        now: Date = Date()
    ) throws -> QuasarPreviewAuthorization {
        cleanup(now: now)
        guard let host = Self.checkedHost(rawHost),
              let token = Self.cookie(named: Self.cookieName, in: cookieHeader),
              let session = sessions[token],
              session.expiresAt > now,
              session.host == host,
              active == session.active
        else { throw QuasarError.authorizationDenied("preview session is invalid or expired") }
        return .init(
            siteID: session.active.siteID,
            generation: session.active.generation,
            upstream: "\(upstreamHost):\(session.active.port)"
        )
    }

    private func cleanup(now: Date) {
        tickets = tickets.filter { $0.value.expiresAt > now }
        sessions = sessions.filter { $0.value.expiresAt > now }
    }

    private static func checkedDomain(_ value: String) -> String? {
        let domain = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, domain.count <= 253, !domain.hasPrefix("."), !domain.hasSuffix("."),
              domain.split(separator: ".").count >= 2,
              domain.split(separator: ".").allSatisfy({ label in
                  !label.isEmpty && label.count <= 63
                      && label.first != "-" && label.last != "-"
                      && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              })
        else { return nil }
        return domain
    }

    private static func checkedHost(_ value: String) -> String? {
        guard !value.isEmpty, !value.contains(":"), !value.contains("/"), !value.contains("\\"),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return value.lowercased()
    }

    private static func checkedUpstreamHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.count <= 253, !host.contains(":"), !host.contains("/"),
              host.split(separator: ".").allSatisfy({ label in
                  !label.isEmpty && label.count <= 63
                      && label.first != "-" && label.last != "-"
                      && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              })
        else { return nil }
        return host
    }

    private static func host(siteID: String, domain: String) -> String {
        "\(siteID.lowercased()).\(domain)"
    }

    private static func isSiteID(_ value: String) -> Bool {
        (1...63).contains(value.utf8.count)
            && value.first != "-" && value.last != "-"
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func isGeneration(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func cookie(named name: String, in header: String) -> String? {
        for component in header.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = component.trimmingCharacters(in: .whitespaces)
            guard let separator = pair.firstIndex(of: "=") else { continue }
            if pair[..<separator] == name {
                let value = String(pair[pair.index(after: separator)...])
                guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { return nil }
                return value.lowercased()
            }
        }
        return nil
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}
