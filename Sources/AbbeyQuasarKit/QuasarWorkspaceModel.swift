import Foundation
import Observation

/// UI-independent state. A view owns the task running observeSelection(); cancellation
/// plus a monotonically increasing revision prevents late responses changing selection.
@MainActor @Observable public final class QuasarWorkspaceModel {
    public let client: any QuasarWorkspaceClient
    public private(set) var sites: [Site] = []
    public var selectedID: String? {
        didSet {
            guard oldValue != selectedID else { return }
            selectionRevision &+= 1
            loadRevision &+= 1
            events = []; review = nil; history = []; preview = .init(); previewURL = nil
        }
    }
    public var name = ""
    public var prompt = ""
    public private(set) var capabilities: QuasarCapabilities?
    public private(set) var events: [GenerationEvent] = []
    public private(set) var review: QuasarPlanReview?
    public private(set) var history: [QuasarHistoryRecord] = []
    public private(set) var archives: [QuasarArchiveReceipt] = []
    public private(set) var proposals: [QuasarProposal] = []
    public private(set) var preview = PreviewStatus()
    public private(set) var previewURL: URL?
    public private(set) var error: String?
    public private(set) var working = false
    public private(set) var connected = false
    public private(set) var uncertainOutcome = false
    private var uncertainSiteID: String?
    private var loadRevision = 0
    private var selectionRevision = 0
    private var refreshRevision = 0

    public init(client: any QuasarWorkspaceClient) { self.client = client }

    @discardableResult public func refresh() async -> Bool {
        refreshRevision &+= 1
        let revision = refreshRevision
        do {
            let caps = try await client.capabilities()
            guard caps.apiVersion == 1, caps.contentReview, caps.durableHistory else { throw QuasarWorkspaceError.incompatibleService }
            if let prior = capabilities, prior.serviceID != caps.serviceID { throw QuasarWorkspaceError.incompatibleService }
            let loaded = try await client.listSites()
            let archived = try await client.archives()
            let proposed = caps.discordApproval ? try await client.proposals() : []
            guard revision == refreshRevision, !Task.isCancelled else { return false }
            connected = true
            capabilities = caps; sites = loaded; archives = archived; proposals = proposed
            if let id = selectedID, !loaded.contains(where: { $0.id == id }) { selectedID = nil }
            if !uncertainOutcome { error = nil }
            return true
        } catch { if revision == refreshRevision, !Task.isCancelled { connected = false; loadRevision &+= 1; self.error = message(error) }; return false }
    }

    @discardableResult public func loadSelection() async -> Bool {
        guard let id = selectedID else { return true }
        guard connected, let expectedIdentity = capabilities?.serviceID else { return false }
        let revision = selectionRevision
        loadRevision &+= 1
        let requestRevision = loadRevision
        do {
            let currentCapabilities = try await client.capabilities()
            guard currentCapabilities.serviceID == expectedIdentity,
                  currentCapabilities.apiVersion == 1, currentCapabilities.contentReview,
                  currentCapabilities.durableHistory else { throw QuasarWorkspaceError.incompatibleService }
            let currentSite = try await client.site(id: id)
            let page = try await client.events(id: id, since: 0)
            let plan = try await client.pendingReview(id: id)
            let records = try await client.history(id: id)
            let status = try await client.previewStatus(id: id)
            guard selectedID == id, revision == selectionRevision, requestRevision == loadRevision, !Task.isCancelled else { return false }
            guard connected, capabilities?.serviceID == expectedIdentity else { return false }
            events = page.events; review = plan; history = records; preview = status
            if let index = sites.firstIndex(where: { $0.id == id }) { sites[index] = currentSite }
            if !uncertainOutcome { error = nil }
            return true
        } catch {
            guard selectedID == id, revision == selectionRevision, requestRevision == loadRevision, !Task.isCancelled else { return false }
            connected = false
            self.error = message(error)
            return false
        }
    }

    public func observeSelection() async {
        let revision = selectionRevision
        repeat {
            if !connected { await refresh() }
            await loadSelection()
            guard !Task.isCancelled, revision == selectionRevision, selectedID != nil else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        } while !Task.isCancelled
    }

    public enum Action: Sendable {
        case create, edit, approve, reject, prepare, startPreview, stopPreview, openPreview, archive
        case rollback(String), restore(QuasarArchiveReceipt), approveProposal(UUID, String), rejectProposal(UUID)
    }

    public func perform(_ action: Action) async {
        guard !working, !uncertainOutcome, connected, capabilities != nil else { return }
        working = true; error = nil
        loadRevision &+= 1
        let id = selectedID
        let revision = selectionRevision
        defer { working = false }
        do {
            switch action {
            case .create:
                let site = try await client.create(name: name, prompt: prompt)
                if selectionRevision == revision { selectedID = site.id; name = ""; prompt = "" }
            case .edit:
                guard let id else { return }
                _ = try await client.edit(id: id, prompt: prompt)
                if selectionRevision == revision { prompt = "" }
            case .approve:
                guard let id, let review, review.siteID == id else { return }
                _ = try await client.approve(id: id, planDigest: review.planDigest)
            case .reject:
                guard let id else { return }; try await client.reject(id: id)
            case .prepare:
                guard let id else { return }; _ = try await client.preparePreview(id: id)
            case .startPreview:
                guard let id else { return }; _ = try await client.startPreview(id: id)
            case .stopPreview:
                guard let id else { return }; _ = try await client.stopPreview(id: id)
                if selectionRevision == revision { previewURL = nil }
            case .openPreview:
                guard let id else { return }
                if capabilities?.privatePreviews == true {
                    let ticket = try await client.previewSession(id: id)
                    guard let url = URL(string: ticket.url), url.scheme == "https", url.user == nil, url.password == nil else { throw QuasarWorkspaceError.invalidResponse }
                    if selectionRevision == revision { previewURL = url }
                } else {
                    let status = try await client.previewStatus(id: id)
                    guard let value = status.url, let url = URL(string: value),
                          ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? ""), url.scheme == "http" else { throw QuasarWorkspaceError.invalidResponse }
                    if selectionRevision == revision { previewURL = url }
                }
            case .archive:
                guard let id else { return }; _ = try await client.archive(id: id)
                if selectionRevision == revision { selectedID = nil }
            case .rollback(let digest):
                guard let id else { return }; _ = try await client.rollback(id: id, planDigest: digest)
            case .restore(let receipt):
                let site = try await client.restore(receipt)
                if selectionRevision == revision { selectedID = site.id }
            case .approveProposal(let id, let digest): try await client.approveProposal(id: id, digest: digest)
            case .rejectProposal(let id): try await client.rejectProposal(id: id)
            }
            await refresh(); await loadSelection()
        } catch {
            if error as? QuasarWorkspaceError == .uncertainOutcome {
                uncertainOutcome = true
                switch action {
                case .create: uncertainSiteID = nil
                case .restore(let receipt): uncertainSiteID = receipt.siteID
                case .approveProposal(let proposalID, _): uncertainSiteID = proposals.first(where: { $0.id == proposalID })?.siteID
                case .rejectProposal: uncertainSiteID = nil
                default: uncertainSiteID = id
                }
            }
            let failure = message(error)
            // Read-only reconciliation never replays a mutation.
            await refresh(); await loadSelection()
            self.error = failure
        }
    }

    public func reconcile(recordID: String, resolution: QuasarRecoveryResolution) async {
        guard !working, let id = selectedID else { return }
        working = true
        defer { working = false }
        guard await refresh(), connected, selectedID == id else { return }
        do {
            let records = try await client.history(id: id)
            guard records.contains(where: { $0.id == recordID && $0.status == .uncertain }) else { throw QuasarError.proposalChanged }
            _ = try await client.reconcileRecovery(id: id, recordID: recordID, resolution: resolution)
            await loadSelection()
        } catch {
            if error as? QuasarWorkspaceError == .uncertainOutcome { uncertainOutcome = true; uncertainSiteID = id }
            self.error = message(error)
        }
    }

    /// Explicit operator acknowledgement uses the original operation's site,
    /// independently of the current UI selection. A create/proposal with no known
    /// site checks the refreshed catalogue, since its dropped response carried no ID.
    public func acknowledgeReconciliation() async {
        guard !working else { return }
        working = true
        defer { working = false }
        guard await refresh(), connected else { return }
        do {
            let ids = uncertainSiteID.map { [$0] }
                ?? Array(Set(sites.map(\.id) + archives.map(\.siteID)))
            for id in ids {
                let records = try await client.history(id: id)
                guard !records.contains(where: { $0.status == .uncertain || $0.status == .applying }) else {
                    error = "The originating operation still has unresolved service history. Select that site and use its explicit recovery action before starting new work."
                    return
                }
            }
            uncertainOutcome = false; uncertainSiteID = nil
            error = "Review the service history and any recovery problems before starting a new operation."
        } catch { self.error = message(error) }
    }

    private func message(_ error: Error) -> String {
        if let error = error as? QuasarWorkspaceError { return error.localizedDescription }
        if let error = error as? QuasarError { return error.localizedDescription }
        return "Quasar could not complete the operation. Reload its state and history."
    }
}
