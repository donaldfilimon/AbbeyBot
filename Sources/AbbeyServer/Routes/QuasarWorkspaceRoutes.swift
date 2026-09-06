import AbbeyQuasarKit
import Foundation
import Vapor

extension QuasarCapabilities: Content {}
extension QuasarProposal: Content {}
extension QuasarPlanReview: Content {}
extension QuasarHistoryRecord: Content {}
extension QuasarDependencyPreparation: Content {}
extension QuasarPreviewTicket: Content {}

private struct RecoveryResolutionDTO: Content { var resolution: QuasarRecoveryResolution }
private struct DiscordProposalApprovalDTO: Content { var digest: String }

func quasarWorkspaceRoutes(_ app: Application, allowsTokenlessLoopback: Bool) {
    let auth = QuasarAuthMiddleware(allowsTokenlessLoopback: allowsTokenlessLoopback)
    let quasar = app.grouped("api", "quasar").grouped(auth)
    let sites = app.grouped("api", "sites").grouped(auth)
    quasar.get("capabilities") { req async throws -> QuasarCapabilities in
        do {
            let client = try await req.application.quasarServiceProvider.workspaceClient()
            var capabilities = try await client.capabilities()
            capabilities.privatePreviews = QuasarInternalPreviewConfiguration.current() != nil
            return capabilities
        } catch { throw mapQuasarError(error) }
    }
    quasar.get("proposals") { req async throws -> [QuasarProposal] in
        let client = try await req.application.quasarServiceProvider.workspaceClient()
        guard try await client.capabilities().discordApproval else { throw Abort(.notImplemented) }
        return try await client.proposals()
    }
    quasar.post("proposals", ":id", "approve") { req async throws -> HTTPStatus in
        let dto = try req.content.decode(DiscordProposalApprovalDTO.self)
        guard let id = UUID(uuidString: try req.parameters.require("id")) else { throw Abort(.badRequest) }
        do {
            let client = try await req.application.quasarServiceProvider.workspaceClient()
            guard try await client.capabilities().discordApproval else { throw Abort(.notImplemented) }
            try await client.approveProposal(id: id, digest: dto.digest)
            return .noContent
        } catch let error as Abort { throw error }
        catch { throw mapQuasarError(error) }
    }
    quasar.post("proposals", ":id", "reject") { req async throws -> HTTPStatus in
        guard let id = UUID(uuidString: try req.parameters.require("id")) else { throw Abort(.badRequest) }
        let client = try await req.application.quasarServiceProvider.workspaceClient()
        guard try await client.capabilities().discordApproval else { throw Abort(.notImplemented) }
        try await client.rejectProposal(id: id)
        return .noContent
    }
    sites.get("archives") { req async throws -> [QuasarArchiveReceipt] in
        do { return try await req.application.quasarServiceProvider.value().archives() }
        catch { throw mapQuasarError(error) }
    }
    sites.get(":id", "plan", "review") { req async throws -> QuasarPlanReview in
        do {
            let service = try await req.application.quasarServiceProvider.value()
            guard let review = try await service.pendingReview(id: req.parameters.require("id")) else { throw Abort(.notFound) }
            // Only this authenticated review route carries source. Prevent browser/proxy caches.
            return review
        } catch let error as Abort { throw error }
        catch { throw mapQuasarError(error) }
    }
    sites.get(":id", "history") { req async throws -> [QuasarHistoryRecord] in
        do { return try await req.application.quasarServiceProvider.value().history(id: req.parameters.require("id")) }
        catch { throw mapQuasarError(error) }
    }
    sites.post(":id", "history", ":recordID", "reconcile") { req async throws -> QuasarHistoryRecord in
        let dto = try req.content.decode(RecoveryResolutionDTO.self)
        do { return try await req.application.quasarServiceProvider.value().reconcileRecovery(
            id: req.parameters.require("id"), recordID: req.parameters.require("recordID"), resolution: dto.resolution) }
        catch { throw mapQuasarError(error) }
    }
    sites.post(":id", "prepare-preview") { req async throws -> QuasarDependencyPreparation in
        do { return try await req.application.quasarServiceProvider.value().preparePreview(id: req.parameters.require("id")) }
        catch { throw mapQuasarError(error) }
    }
    sites.post(":id", "preview-session") { req async throws -> QuasarPreviewTicket in
        guard QuasarInternalPreviewConfiguration.current() != nil else { throw Abort(.notImplemented) }
        do { return try await req.application.quasarServiceProvider.value().previewSession(id: req.parameters.require("id")) }
        catch { throw mapQuasarError(error) }
    }
    quasarInternalPreviewRoutes(app)
}
