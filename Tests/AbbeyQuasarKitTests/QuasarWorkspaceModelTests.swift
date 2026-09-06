import Foundation
import Testing
@testable import AbbeyQuasarKit

@MainActor struct QuasarWorkspaceModelTests {
    @Test func lateSiteResponseCannotReplaceNewSelection() async throws {
        let client = WorkspaceStub()
        let model = QuasarWorkspaceModel(client: client)
        await model.refresh()
        model.selectedID = "first"
        await client.suspendFirst()
        let oldLoad = Task { await model.loadSelection() }
        await client.waitUntilSuspended()
        model.selectedID = "second"
        await model.loadSelection()
        #expect(model.events.first?.text == "second")
        await client.resumeFirst()
        _ = await oldLoad.value
        #expect(model.selectedID == "second")
        #expect(model.events.first?.text == "second")
    }

    @Test func olderSameSiteLoadCannotOverwriteNewerLoad() async {
        let client = WorkspaceStub()
        let model = QuasarWorkspaceModel(client: client)
        await model.refresh()
        model.selectedID = "first"
        await client.suspendFirst()
        let oldLoad = Task { await model.loadSelection() }
        await client.waitUntilSuspended()
        await client.useNewEvents()
        await model.loadSelection()
        #expect(model.events.first?.text == "first-new")
        await client.resumeFirst()
        _ = await oldLoad.value
        #expect(model.events.first?.text == "first-new")
    }

    @Test func connectionFailureRetainsLoadedSitesAndEvents() async {
        let client = WorkspaceStub()
        let model = QuasarWorkspaceModel(client: client)
        await model.refresh()
        model.selectedID = "second"
        await model.loadSelection()
        await client.failReads()
        await model.refresh(); await model.loadSelection()
        #expect(model.sites.count == 2)
        #expect(model.events.first?.text == "second")
        #expect(model.error != nil)
    }

    @Test func droppedMutationResponseIsNeverAutomaticallyReplayed() async {
        let client = WorkspaceStub()
        let model = QuasarWorkspaceModel(client: client)
        await model.refresh()
        model.name = "Test"; model.prompt = "Test prompt"
        await model.perform(.create)
        await model.perform(.create)
        #expect(await client.createCount == 1)
        #expect(model.uncertainOutcome)
        #expect(model.error?.contains("Do not repeat") == true)
    }

    @Test func recoveryCannotWriteToAReplacementService() async {
        let client = WorkspaceStub()
        let model = QuasarWorkspaceModel(client: client)
        await model.refresh(); model.selectedID = "first"
        await client.markUnresolved(siteID: "first")
        await model.loadSelection()
        let recordID = model.history[0].id
        await client.changeIdentity()
        await model.reconcile(recordID: recordID, resolution: .confirmedNotApplied)
        #expect(await client.reconcileCount == 0)
        #expect(!model.connected)
    }

    @Test func droppedRecoveryResponseLatchesUncertainty() async {
        let client = WorkspaceStub()
        let model = QuasarWorkspaceModel(client: client)
        await model.refresh(); model.selectedID = "first"
        await client.markUnresolved(siteID: "first"); await model.loadSelection()
        await model.reconcile(recordID: model.history[0].id, resolution: .confirmedNotApplied)
        #expect(await client.reconcileCount == 1)
        #expect(model.uncertainOutcome)
    }

    @Test func droppedCreateChecksCatalogueHistoryWithoutASelection() async {
        let client = WorkspaceStub()
        let model = QuasarWorkspaceModel(client: client)
        await model.refresh(); model.name = "New"; model.prompt = "Create"
        await model.perform(.create)
        await client.markUnresolved(siteID: "first")
        model.selectedID = nil
        await model.acknowledgeReconciliation()
        #expect(model.uncertainOutcome)
    }

    @Test func uncertainOutcomeRemainsBoundToOriginatingSite() async {
        let client = WorkspaceStub()
        let model = QuasarWorkspaceModel(client: client)
        await model.refresh()
        model.selectedID = "first"; model.prompt = "Edit"
        await client.markUnresolved(siteID: "first")
        await model.perform(.edit)
        model.selectedID = "second"
        await model.acknowledgeReconciliation()
        #expect(model.uncertainOutcome)
        #expect(model.error?.contains("originating operation") == true)
    }

    @Test func reconnectingToDifferentServiceRejectsItsState() async {
        let client = WorkspaceStub()
        let model = QuasarWorkspaceModel(client: client)
        await model.refresh()
        model.selectedID = "second"
        await model.loadSelection()
        await client.changeIdentity()
        await model.refresh()
        await model.loadSelection()
        #expect(model.events.first?.text == "second")
        #expect(model.capabilities?.serviceID == "original")
        #expect(model.error == QuasarWorkspaceError.incompatibleService.localizedDescription)
        #expect(!model.connected)
        model.name = "New"; model.prompt = "Prompt"
        await model.perform(.create)
        #expect(await client.createCount == 0)
    }
}

private actor WorkspaceStub: QuasarWorkspaceClient {
    var createCount = 0
    var reconcileCount = 0
    private var readsFail = false
    private var identity = "original"
    private var unresolvedSites: Set<String> = []
    func markUnresolved(siteID: String) { unresolvedSites.insert(siteID) }
    private var shouldSuspend = false
    private var eventSuffix = ""
    func useNewEvents() { eventSuffix = "-new" }
    private var suspended: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func suspendFirst() { shouldSuspend = true }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resumeFirst() { suspended?.resume(); suspended = nil }
    func failReads() { readsFail = true }
    func changeIdentity() { identity = "replacement" }
    func capabilities() throws -> QuasarCapabilities {
        if readsFail { throw QuasarWorkspaceError.connection }
        return .init(serviceID: identity, discordApproval: false)
    }
    func listSites() throws -> [Site] {
        if readsFail { throw QuasarWorkspaceError.connection }
        return [Site(id: "first", name: "First", slug: "first"), Site(id: "second", name: "Second", slug: "second")]
    }
    func site(id: String) -> Site { Site(id: id, name: id, slug: id) }
    func events(id: String, since: Int) async throws -> EventPage {
        if readsFail { throw QuasarWorkspaceError.connection }
        let eventText = id + eventSuffix
        if id == "first", shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { suspended = $0; for waiter in waiters { waiter.resume() }; waiters = [] }
        }
        return .init(events: [.text(eventText)], next: 1)
    }
    func create(name: String, prompt: String) throws -> Site { createCount += 1; throw QuasarWorkspaceError.uncertainOutcome }
    func edit(id: String, prompt: String) throws -> Site { throw QuasarWorkspaceError.uncertainOutcome }
    func pendingReview(id: String) -> QuasarPlanReview? { nil }
    func approve(id: String, planDigest: String) throws -> QuasarMutationReceipt { throw QuasarError.notFound }
    func reject(id: String) {}
    func history(id: String) -> [QuasarHistoryRecord] {
        unresolvedSites.contains(id) ? [.init(id: "record-" + id, siteID: id, kind: .mutation, status: .uncertain)] : []
    }
    func reconcileRecovery(id: String, recordID: String, resolution: QuasarRecoveryResolution) throws -> QuasarHistoryRecord { reconcileCount += 1; throw QuasarWorkspaceError.uncertainOutcome }
    func archives() -> [QuasarArchiveReceipt] { [] }
    func rollback(id: String, planDigest: String) throws -> QuasarRollbackReceipt { throw QuasarError.notFound }
    func archive(id: String) throws -> QuasarArchiveReceipt { throw QuasarError.notFound }
    func restore(_ receipt: QuasarArchiveReceipt) throws -> Site { throw QuasarError.notFound }
    func previewStatus(id: String) -> PreviewStatus { .init() }
    func preparePreview(id: String) throws -> QuasarDependencyPreparation { throw QuasarError.notFound }
    func startPreview(id: String) -> PreviewStatus { .init() }
    func stopPreview(id: String) -> PreviewStatus { .init() }
    func previewSession(id: String) throws -> QuasarPreviewTicket { throw QuasarError.notFound }
    func proposals() -> [QuasarProposal] { [] }
    func approveProposal(id: UUID, digest: String) {}
    func rejectProposal(id: UUID) {}
}
