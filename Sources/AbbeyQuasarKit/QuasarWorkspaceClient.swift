import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct QuasarCapabilities: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var serviceID: String
    public var discordApproval: Bool
    public var contentReview: Bool
    public var durableHistory: Bool
    public var privatePreviews: Bool
    public init(serviceID: String, discordApproval: Bool, privatePreviews: Bool = false) {
        apiVersion = 1; self.serviceID = serviceID; self.discordApproval = discordApproval
        contentReview = true; durableHistory = true; self.privatePreviews = privatePreviews
    }
}

public enum QuasarWorkspaceError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint, connection, unauthorized, incompatibleService, uncertainOutcome, rejected(Int), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Use an HTTPS service origin, or HTTP on exact localhost, 127.0.0.1, or ::1. Credentials, paths, queries and fragments are not allowed."
        case .connection: return "Unable to reach the Quasar service. Previously loaded data has been retained."
        case .unauthorized: return "The Quasar service rejected the dedicated API credentials."
        case .incompatibleService: return "This service does not support the required Quasar review and recovery API."
        case .uncertainOutcome: return "The connection ended before the operation was confirmed. Do not repeat the operation; reload the owning service's state and history to reconcile its outcome."
        case .rejected(let status): return "The Quasar service rejected the operation (HTTP \(status)). Reload its current state before continuing."
        case .invalidResponse: return "The Quasar service returned an invalid or oversized response."
        }
    }
}

public enum QuasarEndpointPolicy {
    public static func validate(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value), let url = parts.url,
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else { throw QuasarWorkspaceError.invalidEndpoint }
        return url
    }
    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? (lhs.scheme == "https" ? 443 : 80)) == (rhs.port ?? (rhs.scheme == "https" ? 443 : 80))
            && rhs.user == nil && rhs.password == nil
    }
}

/// An immutable backend is selected at process startup. Mutations are never retried.
public protocol QuasarWorkspaceClient: Sendable {
    func capabilities() async throws -> QuasarCapabilities
    func listSites() async throws -> [Site]
    func site(id: String) async throws -> Site
    func create(name: String, prompt: String) async throws -> Site
    func edit(id: String, prompt: String) async throws -> Site
    func events(id: String, since: Int) async throws -> EventPage
    func pendingReview(id: String) async throws -> QuasarPlanReview?
    func approve(id: String, planDigest: String) async throws -> QuasarMutationReceipt
    func reject(id: String) async throws
    func history(id: String) async throws -> [QuasarHistoryRecord]
    func reconcileRecovery(id: String, recordID: String, resolution: QuasarRecoveryResolution) async throws -> QuasarHistoryRecord
    func archives() async throws -> [QuasarArchiveReceipt]
    func rollback(id: String, planDigest: String) async throws -> QuasarRollbackReceipt
    func archive(id: String) async throws -> QuasarArchiveReceipt
    func restore(_ receipt: QuasarArchiveReceipt) async throws -> Site
    func previewStatus(id: String) async throws -> PreviewStatus
    func preparePreview(id: String) async throws -> QuasarDependencyPreparation
    func startPreview(id: String) async throws -> PreviewStatus
    func stopPreview(id: String) async throws -> PreviewStatus
    func previewSession(id: String) async throws -> QuasarPreviewTicket
    func proposals() async throws -> [QuasarProposal]
    func approveProposal(id: UUID, digest: String) async throws
    func rejectProposal(id: UUID) async throws
}

/// The owner supplies the permission lookup; callers cannot submit permission facts.
public struct LocalQuasarWorkspaceClient: QuasarWorkspaceClient {
    private let service: QuasarService
    private let approveDiscord: (@Sendable (UUID, String) async throws -> Void)?
    public init(service: QuasarService, approveDiscord: (@Sendable (UUID, String) async throws -> Void)? = nil) {
        self.service = service; self.approveDiscord = approveDiscord
    }
    public func capabilities() async throws -> QuasarCapabilities {
        let identity = try await service.serviceIdentity()
        return .init(serviceID: identity, discordApproval: approveDiscord != nil)
    }
    public func listSites() async throws -> [Site] { await service.listSites() }
    public func site(id: String) async throws -> Site { try await service.site(id: id) }
    public func create(name: String, prompt: String) async throws -> Site { try await service.create(name: name, prompt: prompt) }
    public func edit(id: String, prompt: String) async throws -> Site { try await service.edit(id: id, prompt: prompt) }
    public func events(id: String, since: Int) async throws -> EventPage { try await service.events(id: id, since: since) }
    public func pendingReview(id: String) async throws -> QuasarPlanReview? { try await service.pendingReview(id: id) }
    public func approve(id: String, planDigest: String) async throws -> QuasarMutationReceipt { try await service.approve(id: id, planDigest: planDigest) }
    public func reject(id: String) async throws { try await service.reject(id: id) }
    public func history(id: String) async throws -> [QuasarHistoryRecord] { try await service.history(id: id) }
    public func reconcileRecovery(id: String, recordID: String, resolution: QuasarRecoveryResolution) async throws -> QuasarHistoryRecord {
        try await service.reconcileRecovery(id: id, recordID: recordID, resolution: resolution)
    }
    public func archives() async throws -> [QuasarArchiveReceipt] { try await service.archives() }
    public func rollback(id: String, planDigest: String) async throws -> QuasarRollbackReceipt { try await service.rollback(id: id, planDigest: planDigest) }
    public func archive(id: String) async throws -> QuasarArchiveReceipt { try await service.archive(id: id) }
    public func restore(_ receipt: QuasarArchiveReceipt) async throws -> Site { try await service.restore(receipt) }
    public func previewStatus(id: String) async throws -> PreviewStatus { try await service.previewStatus(id: id) }
    public func preparePreview(id: String) async throws -> QuasarDependencyPreparation { try await service.preparePreview(id: id) }
    public func startPreview(id: String) async throws -> PreviewStatus { try await service.startPreview(id: id) }
    public func stopPreview(id: String) async throws -> PreviewStatus { try await service.stopPreview(id: id) }
    public func previewSession(id: String) async throws -> QuasarPreviewTicket { try await service.previewSession(id: id) }
    public func proposals() async throws -> [QuasarProposal] { await service.pendingDiscordProposals() }
    public func approveProposal(id: UUID, digest: String) async throws {
        guard let approveDiscord else { throw QuasarWorkspaceError.incompatibleService }
        try await approveDiscord(id, digest)
    }
    public func rejectProposal(id: UUID) async throws { await service.cancelDiscordProposal(id: id) }
}
