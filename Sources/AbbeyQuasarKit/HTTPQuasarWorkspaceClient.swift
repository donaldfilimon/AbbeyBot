import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reject redirects entirely: a redirect can obscure whether a mutation already ran,
/// even on the same origin. Cookies/cache are also disabled for operator traffic.
private final class QuasarRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct HTTPQuasarWorkspaceClient: QuasarWorkspaceClient {
    public let endpoint: URL
    private let token: String
    private let session: URLSession
    private let redirectGuard = QuasarRedirectGuard()
    public init(endpoint: String, token: String) throws {
        try self.init(endpoint: endpoint, token: token, configuration: .ephemeral)
    }
    init(endpoint: String, token: String, configuration: URLSessionConfiguration) throws {
        self.endpoint = try QuasarEndpointPolicy.validate(endpoint)
        self.token = token
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 360
        session = URLSession(configuration: configuration)
    }

    private func request<T: Decodable & Sendable>(_ components: [String], method: String = "GET", body: Data? = nil,
                                                 query: [URLQueryItem] = [], missing: Bool = false) async throws -> T? {
        var url = endpoint
        for component in components { url.appendPathComponent(component) }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let mutation = method != "GET"
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: redirectGuard) }
        catch is CancellationError {
            // Cancellation only ends the local wait; the owning service may
            // already have applied a dispatched mutation.
            if mutation { throw QuasarWorkspaceError.uncertainOutcome }
            throw CancellationError()
        }
        catch { throw mutation ? QuasarWorkspaceError.uncertainOutcome : .connection }
        guard let http = response as? HTTPURLResponse else { throw mutation ? QuasarWorkspaceError.uncertainOutcome : .invalidResponse }
        if missing && http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw QuasarWorkspaceError.unauthorized }
            if mutation && (http.statusCode >= 500 || (300..<400).contains(http.statusCode)) { throw QuasarWorkspaceError.uncertainOutcome }
            throw QuasarWorkspaceError.rejected(http.statusCode)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as? T }
        guard data.count <= 12 * 1024 * 1024 else { throw mutation ? QuasarWorkspaceError.uncertainOutcome : .invalidResponse }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch { throw mutation ? QuasarWorkspaceError.uncertainOutcome : .invalidResponse }
    }
    private func get<T: Decodable & Sendable>(_ path: [String]) async throws -> T {
        guard let value: T = try await request(path) else { throw QuasarWorkspaceError.invalidResponse }; return value
    }
    private func send<T: Decodable & Sendable, Body: Encodable>(_ path: [String], body: Body, method: String = "POST") async throws -> T {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let value: T = try await request(path, method: method, body: encoder.encode(body)) else { throw QuasarWorkspaceError.uncertainOutcome }; return value
    }
    private struct EmptyResponse: Codable, Sendable {}
    private struct Prompt: Codable { var prompt: String }
    private struct Digest: Codable { var planDigest: String }
    private struct Resolution: Codable { var resolution: QuasarRecoveryResolution }
    private struct ProposalDigest: Codable { var digest: String }

    public func capabilities() async throws -> QuasarCapabilities {
        let value: QuasarCapabilities = try await get(["api", "quasar", "capabilities"])
        guard value.apiVersion == 1, value.contentReview, value.durableHistory, !value.serviceID.isEmpty else { throw QuasarWorkspaceError.incompatibleService }
        return value
    }
    public func listSites() async throws -> [Site] { try await get(["api", "sites"]) }
    public func site(id: String) async throws -> Site { try await get(["api", "sites", id]) }
    public func create(name: String, prompt: String) async throws -> Site { try await send(["api", "sites"], body: CreateSiteRequest(name: name, prompt: prompt)) }
    public func edit(id: String, prompt: String) async throws -> Site { try await send(["api", "sites", id, "edit"], body: Prompt(prompt: prompt)) }
    public func events(id: String, since: Int) async throws -> EventPage {
        guard let page: EventPage = try await request(["api", "sites", id, "events"], query: [.init(name: "since", value: String(max(0, since)))]) else { throw QuasarWorkspaceError.invalidResponse }; return page
    }
    public func pendingReview(id: String) async throws -> QuasarPlanReview? { try await request(["api", "sites", id, "plan", "review"], missing: true) }
    public func approve(id: String, planDigest: String) async throws -> QuasarMutationReceipt { try await send(["api", "sites", id, "plan", "approve"], body: Digest(planDigest: planDigest)) }
    public func reject(id: String) async throws { let _: EmptyResponse = try await send(["api", "sites", id, "plan", "reject"], body: EmptyResponse()) }
    public func history(id: String) async throws -> [QuasarHistoryRecord] { try await get(["api", "sites", id, "history"]) }
    public func reconcileRecovery(id: String, recordID: String, resolution: QuasarRecoveryResolution) async throws -> QuasarHistoryRecord {
        try await send(["api", "sites", id, "history", recordID, "reconcile"], body: Resolution(resolution: resolution))
    }
    public func archives() async throws -> [QuasarArchiveReceipt] { try await get(["api", "sites", "archives"]) }
    public func rollback(id: String, planDigest: String) async throws -> QuasarRollbackReceipt { try await send(["api", "sites", id, "rollback"], body: Digest(planDigest: planDigest)) }
    public func archive(id: String) async throws -> QuasarArchiveReceipt { try await send(["api", "sites", id], body: EmptyResponse(), method: "DELETE") }
    public func restore(_ receipt: QuasarArchiveReceipt) async throws -> Site { try await send(["api", "sites", "restore"], body: receipt) }
    public func previewStatus(id: String) async throws -> PreviewStatus { try await get(["api", "sites", id, "preview"]) }
    public func preparePreview(id: String) async throws -> QuasarDependencyPreparation { try await send(["api", "sites", id, "prepare-preview"], body: EmptyResponse()) }
    public func startPreview(id: String) async throws -> PreviewStatus { try await send(["api", "sites", id, "preview", "start"], body: EmptyResponse()) }
    public func stopPreview(id: String) async throws -> PreviewStatus { try await send(["api", "sites", id, "preview", "stop"], body: EmptyResponse()) }
    public func previewSession(id: String) async throws -> QuasarPreviewTicket { try await send(["api", "sites", id, "preview-session"], body: EmptyResponse()) }
    public func proposals() async throws -> [QuasarProposal] { try await get(["api", "quasar", "proposals"]) }
    public func approveProposal(id: UUID, digest: String) async throws { let _: EmptyResponse = try await send(["api", "quasar", "proposals", id.uuidString, "approve"], body: ProposalDigest(digest: digest)) }
    public func rejectProposal(id: UUID) async throws { let _: EmptyResponse = try await send(["api", "quasar", "proposals", id.uuidString, "reject"], body: EmptyResponse()) }
}
