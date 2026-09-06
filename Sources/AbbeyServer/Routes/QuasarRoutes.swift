import AbbeyQuasarKit
import Foundation
import Vapor

extension Site: Content {}
extension EventPage: Content {}
extension PreviewStatus: Content {}
extension QuasarMutationPreview: Content {}
extension QuasarMutationReceipt: Content {}
extension QuasarRollbackReceipt: Content {}
extension QuasarArchiveReceipt: Content {}

actor QuasarServiceProvider {
    private let planner: QuasarPlanner
    private var service: QuasarService?
    let approveDiscord: (@Sendable (UUID, String) async throws -> Void)?
    init(service: QuasarService?, planner: QuasarPlanner,
         approveDiscord: (@Sendable (UUID, String) async throws -> Void)? = nil) {
        self.service = service; self.planner = planner; self.approveDiscord = approveDiscord
    }

    func workspaceClient() throws -> LocalQuasarWorkspaceClient {
        LocalQuasarWorkspaceClient(service: try value(), approveDiscord: approveDiscord)
    }

    func value() throws -> QuasarService {
        if let service { return service }
        let created = try QuasarService(planner: planner)
        service = created
        return created
    }

    /// Shutdown never creates a service merely to stop it.
    func shutdown() async {
        guard let service else { return }
        await service.shutdown()
    }
}

struct QuasarServiceLifecycleHandler: LifecycleHandler {
    let provider: QuasarServiceProvider

    func shutdownAsync(_ app: Application) async {
        await provider.shutdown()
    }
}

private struct QuasarServiceProviderKey: StorageKey {
    typealias Value = QuasarServiceProvider
}

extension Application {
    var quasarServiceProvider: QuasarServiceProvider {
        get {
            guard let value = storage[QuasarServiceProviderKey.self] else {
                fatalError("QuasarServiceProvider not configured")
            }
            return value
        }
        set { storage[QuasarServiceProviderKey.self] = newValue }
    }
}

struct QuasarAuthMiddleware: AsyncMiddleware {
    let token: String
    let allowedOrigins: Set<String>
    let allowsTokenlessLoopback: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowsTokenlessLoopback: Bool
    ) {
        self.token = environment["ABBEY_QUASAR_API_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.allowedOrigins = Set((environment["ABBEY_QUASAR_ALLOWED_ORIGINS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(QuasarServePolicy.isValidExactHTTPSOrigin))
        self.allowsTokenlessLoopback = allowsTokenlessLoopback
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if let origin = request.headers.first(name: .origin), !allowedOrigin(origin) {
            throw Abort(.forbidden, reason: "Quasar origin is not allowlisted")
        }
        let isAllowedPreflight = request.method == .OPTIONS
            && request.headers.first(name: .origin) != nil
        if !isAllowedPreflight {
            // Browser preflights do not carry the eventual Authorization
            // header. Origin validation above remains mandatory; authenticate
            // the actual request that follows.
            if token.isEmpty {
                let ip = request.remoteAddress?.ipAddress ?? ""
                guard allowsTokenlessLoopback,
                      ip == "127.0.0.1" || ip == "::1"
                else {
                    throw Abort(.serviceUnavailable, reason: "ABBEY_QUASAR_API_TOKEN is required for this Quasar server mode")
                }
            } else {
                let bearer = request.headers.bearerAuthorization?.token
                let alternate = request.headers.first(name: "X-Abbey-Quasar-Token")
                guard Self.constantTimeEqual(bearer ?? alternate ?? "", token) else { throw Abort(.unauthorized) }
            }
        }
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        if let origin = request.headers.first(name: .origin), allowedOrigin(origin) {
            response.headers.replaceOrAdd(name: .accessControlAllowOrigin, value: origin)
            response.headers.replaceOrAdd(name: .vary, value: "Origin")
        }
        return response
    }

    private func allowedOrigin(_ origin: String) -> Bool {
        QuasarServePolicy.isValidBrowserOrigin(
            origin,
            configuredRemoteOrigins: allowedOrigins
        )
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt64(a.count ^ b.count)
        for index in 0..<max(a.count, b.count) {
            difference |= UInt64(
                (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
            )
        }
        return difference == 0
    }
}

private struct CreateSiteDTO: Content { var name: String; var prompt: String }
private struct EditSiteDTO: Content { var prompt: String }
private struct ApprovePlanDTO: Content { var planDigest: String }
private struct RollbackPlanDTO: Content { var planDigest: String }

func quasarRoutes(_ app: Application, allowsTokenlessLoopback: Bool) {
    quasarWorkspaceRoutes(app, allowsTokenlessLoopback: allowsTokenlessLoopback)
    let sites = app.grouped("api", "sites").grouped(QuasarAuthMiddleware(
        allowsTokenlessLoopback: allowsTokenlessLoopback
    ))

    sites.on(.OPTIONS, "**") { req async throws -> Response in
        let response = Response(status: .noContent)
        response.headers.replaceOrAdd(name: .accessControlAllowMethods, value: "GET, POST, DELETE, OPTIONS")
        response.headers.replaceOrAdd(name: .accessControlAllowHeaders, value: "Authorization, Content-Type, X-Abbey-Quasar-Token")
        return response
    }

    sites.get { req async throws -> [Site] in
        let service = try await req.application.quasarServiceProvider.value()
        return await service.listSites()
    }
    sites.post { req async throws -> Response in
        let body = try req.content.decode(CreateSiteDTO.self)
        do {
            let service = try await req.application.quasarServiceProvider.value()
            let site = try await service.create(name: body.name, prompt: body.prompt)
            return try await site.encodeResponse(status: .accepted, for: req)
        } catch { throw mapQuasarError(error, req.logger) }
    }
    sites.post("restore") { req async throws -> Site in
        let receipt = try req.content.decode(QuasarArchiveReceipt.self)
        do {
            let service = try await req.application.quasarServiceProvider.value()
            return try await service.restore(receipt)
        } catch { throw mapQuasarError(error, req.logger) }
    }
    sites.get(":id") { req async throws -> Site in
        do {
            let service = try await req.application.quasarServiceProvider.value()
            return try await service.site(id: try req.parameters.require("id"))
        }
        catch { throw mapQuasarError(error, req.logger) }
    }
    sites.post(":id", "edit") { req async throws -> Response in
        let body = try req.content.decode(EditSiteDTO.self)
        do {
            let service = try await req.application.quasarServiceProvider.value()
            let site = try await service.edit(id: try req.parameters.require("id"), prompt: body.prompt)
            return try await site.encodeResponse(status: .accepted, for: req)
        } catch { throw mapQuasarError(error, req.logger) }
    }
    sites.get(":id", "events") { req async throws -> EventPage in
        do {
            let service = try await req.application.quasarServiceProvider.value()
            return try await service.events(id: try req.parameters.require("id"), since: max(req.query[Int.self, at: "since"] ?? 0, 0))
        }
        catch { throw mapQuasarError(error, req.logger) }
    }
    sites.get(":id", "plan") { req async throws -> QuasarMutationPreview in
        do {
            let service = try await req.application.quasarServiceProvider.value()
            guard let plan = try await service.pendingPlan(id: try req.parameters.require("id")) else {
                throw Abort(.notFound, reason: "No mutation plan is awaiting approval")
            }
            return plan
        } catch let abort as Abort { throw abort }
        catch { throw mapQuasarError(error, req.logger) }
    }
    sites.post(":id", "plan", "approve") { req async throws -> QuasarMutationReceipt in
        let body = try req.content.decode(ApprovePlanDTO.self)
        do {
            let service = try await req.application.quasarServiceProvider.value()
            return try await service.approve(id: try req.parameters.require("id"), planDigest: body.planDigest)
        } catch { throw mapQuasarError(error, req.logger) }
    }
    sites.post(":id", "plan", "reject") { req async throws -> HTTPStatus in
        do {
            let service = try await req.application.quasarServiceProvider.value()
            try await service.reject(id: try req.parameters.require("id"))
            return .noContent
        } catch { throw mapQuasarError(error, req.logger) }
    }
    sites.post(":id", "rollback") { req async throws -> QuasarRollbackReceipt in
        let body = try req.content.decode(RollbackPlanDTO.self)
        do {
            let service = try await req.application.quasarServiceProvider.value()
            return try await service.rollback(id: try req.parameters.require("id"), planDigest: body.planDigest)
        } catch { throw mapQuasarError(error, req.logger) }
    }
    sites.get(":id", "preview") { req async throws -> PreviewStatus in
        do {
            let service = try await req.application.quasarServiceProvider.value()
            return try await service.previewStatus(id: try req.parameters.require("id"))
        }
        catch { throw mapQuasarError(error, req.logger) }
    }
    sites.post(":id", "preview", "start") { req async throws -> PreviewStatus in
        do {
            let service = try await req.application.quasarServiceProvider.value()
            return try await service.startPreview(id: try req.parameters.require("id"))
        }
        catch { throw mapQuasarError(error, req.logger) }
    }
    sites.post(":id", "preview", "stop") { req async throws -> PreviewStatus in
        do {
            let service = try await req.application.quasarServiceProvider.value()
            return try await service.stopPreview(id: try req.parameters.require("id"))
        }
        catch { throw mapQuasarError(error, req.logger) }
    }
    sites.delete(":id") { req async throws -> Response in
        do {
            let service = try await req.application.quasarServiceProvider.value()
            let receipt = try await service.archive(id: try req.parameters.require("id"))
            return try await receipt.encodeResponse(status: .ok, for: req)
        } catch { throw mapQuasarError(error, req.logger) }
    }
}

/// Map a Quasar failure to a client response.
///
/// The catch-all deliberately withholds the cause from the client, and its
/// reason tells the operator to read the logs instead -- but nothing wrote one,
/// so the cause reached neither the client nor the operator. A release-gate
/// boot failure surfaced as a bare 500 with no diagnosis anywhere, at a cost of
/// one full container build per guess. Pass the request logger so the promised
/// operator record exists; the client response is unchanged.
func mapQuasarError(_ error: Error, _ logger: Logger? = nil) -> Abort {
    switch error {
    case QuasarError.notFound: return Abort(.notFound)
    case QuasarError.jobRunning, QuasarError.proposalChanged: return Abort(.conflict, reason: error.localizedDescription)
    case QuasarError.proposalExpired: return Abort(.gone, reason: error.localizedDescription)
    case QuasarError.authorizationDenied: return Abort(.forbidden, reason: error.localizedDescription)
    case QuasarError.invalidInput, QuasarError.pathRejected, QuasarError.fileTooLarge,
         QuasarError.malformedPlan, QuasarError.budgetExceeded: return Abort(.badRequest, reason: error.localizedDescription)
    case QuasarError.providerUnqualified: return Abort(.serviceUnavailable, reason: error.localizedDescription)
    default:
        // `String(reflecting:)` keeps the case and its associated value, which is
        // what distinguishes registryLocked from processFailed("...").
        logger?.error(
            "Quasar operation failed",
            metadata: ["quasarError": .string(String(reflecting: error))]
        )
        return Abort(.internalServerError, reason: "Quasar operation failed; inspect redacted operator logs")
    }
}
