import AbbeyQuasarKit
import Foundation
import Vapor

struct QuasarInternalPreviewConfiguration: Sendable {
    let token: String
    let domain: String
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard let token = environment["ABBEY_QUASAR_PREVIEW_INTERNAL_TOKEN"], token.utf8.count >= 32,
              let domain = environment["ABBEY_QUASAR_PREVIEW_DOMAIN"]?.lowercased(),
              let url = try? QuasarEndpointPolicy.validate("https://\(domain)"), url.host == domain,
              domain.contains("."), !domain.contains(":") else { return nil }
        return .init(token: token, domain: domain)
    }
    func permits(_ request: Request) -> Bool {
        let supplied = request.headers.first(name: "X-Abbey-Preview-Service-Token") ?? ""
        let a = Array(token.utf8), b = Array(supplied.utf8)
        var diff = a.count ^ b.count
        for index in 0..<max(a.count, b.count) { diff |= Int((index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)) }
        guard diff == 0, let host = request.headers.first(name: "X-Abbey-Preview-Host")?.lowercased(),
              host.hasSuffix(".\(domain)") else { return false }
        let site = String(host.dropLast(domain.count + 1))
        // Site identifiers are server-generated UUIDs, never arbitrary hosts or upstreams.
        return UUID(uuidString: site) != nil
    }
}

/// Caddy's preview vhost is the only public entry. The operator vhost blocks
/// /internal/* and never possesses this credential. Both checks are required.
func quasarInternalPreviewRoutes(_ app: Application) {
    app.get("internal", "quasar", "preview", "redeem") { req async throws -> Response in
        guard let config = QuasarInternalPreviewConfiguration.current() else { throw Abort(.notFound) }
        guard config.permits(req) else { throw Abort(.unauthorized) }
        let host = req.headers.first(name: "X-Abbey-Preview-Host")!
        guard let ticket = req.query[String.self, at: "ticket"], ticket.utf8.count <= 256 else { throw Abort(.badRequest) }
        do {
            let service = try await req.application.quasarServiceProvider.value()
            let grant = try await service.preview.access.redeem(ticket: ticket, host: host)
            let response = Response(status: .seeOther)
            response.headers.replaceOrAdd(name: .setCookie, value: grant.setCookie)
            response.headers.replaceOrAdd(name: .location, value: grant.redirectURL)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
            return response
        } catch { throw Abort(.unauthorized, reason: "Preview access is invalid or expired") }
    }
    app.get("internal", "quasar", "preview", "authorize") { req async throws -> Response in
        guard let config = QuasarInternalPreviewConfiguration.current() else { throw Abort(.notFound) }
        guard config.permits(req) else { throw Abort(.unauthorized) }
        let host = req.headers.first(name: "X-Abbey-Preview-Host")!
        let cookies = req.headers.first(name: .cookie) ?? ""
        guard cookies.utf8.count <= 16_384 else { throw Abort(.unauthorized) }
        do {
            let service = try await req.application.quasarServiceProvider.value()
            let authorization = try await service.preview.access.authorize(host: host, cookieHeader: cookies)
            let status = try await service.previewStatus(id: authorization.siteID)
            guard status.state == .running else { throw Abort(.unauthorized) }
            // Checking status reconciles exited processes; verify generation again afterward.
            let current = try await service.preview.access.authorize(host: host, cookieHeader: cookies)
            guard current == authorization else { throw Abort(.unauthorized) }
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: "X-Quasar-Upstream", value: authorization.upstream)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        } catch { throw Abort(.unauthorized, reason: "Preview access is invalid or expired") }
    }
}
