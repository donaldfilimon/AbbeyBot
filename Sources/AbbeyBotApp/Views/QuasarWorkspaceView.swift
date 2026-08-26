import AbbeyQuasarKit
import SwiftUI

struct QuasarWorkspaceView: View {
    @Environment(AbbeyEngine.self) private var engine
    @State private var sites: [Site] = []
    @State private var selectedID: String?
    @State private var name = ""
    @State private var prompt = ""
    @State private var events: [GenerationEvent] = []
    @State private var pendingPlan: QuasarMutationPreview?
    @State private var discordProposals: [QuasarProposal] = []
    @State private var lastMutationReceipt: QuasarMutationReceipt?
    @State private var lastArchiveReceipt: QuasarArchiveReceipt?
    @State private var previewStatus = PreviewStatus()
    @State private var error: String?
    @State private var working = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sites").font(.headline)
                List(sites, selection: $selectedID) { site in
                    VStack(alignment: .leading) {
                        Text(site.name)
                        Text(site.status.rawValue).font(.caption).foregroundStyle(site.status == .error ? .red : .secondary)
                    }.tag(site.id)
                }
                Button("Refresh") { refresh() }
            }.frame(minWidth: 220).padding()

            VStack(alignment: .leading, spacing: 12) {
                if !discordProposals.isEmpty {
                    Text("Discord proposals").font(.title2.bold())
                    ForEach(discordProposals) { proposal in
                        GroupBox(proposal.summary) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Initiator \(proposal.facts.initiatorID) · guild \(proposal.facts.guildID) · expires \(proposal.expiresAt.formatted())")
                                Text("Digest: \(proposal.digest)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Text(proposal.impact)
                                Text("Rollback: \(proposal.rollback)").foregroundStyle(.secondary)
                                Text(verbatim: "owner=\(proposal.facts.ownerAllowed) permission=\(proposal.facts.discordPermissionAllowed) optIn=\(proposal.facts.guildOptedIn) quiet=\(proposal.facts.quiet) budget=\(proposal.facts.remainingBudget)")
                                    .font(.system(.caption, design: .monospaced))
                                HStack {
                                    Button("Confirm after revalidation") { approveDiscord(proposal) }.buttonStyle(.borderedProminent)
                                    Button("Reject", role: .destructive) { rejectDiscord(proposal) }
                                }.disabled(working)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider()
                }
                Text("Create with Abbey").font(.title2.bold())
                TextField("Site name", text: $name).textFieldStyle(.roundedBorder)
                TextEditor(text: $prompt).frame(minHeight: 100).overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                HStack {
                    Button("Prepare change plan") { create() }
                        .disabled(working || name.isEmpty || prompt.isEmpty || engine.quasarService == nil)
                    if working { ProgressView().controlSize(.small) }
                }
                Text("Planning is read-only. Generated writes remain sealed until you review the digest and approve this exact plan.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let receipt = lastMutationReceipt {
                    HStack {
                        Text("Applied plan \(receipt.planDigest.prefix(12))…").font(.caption).foregroundStyle(.secondary)
                        Button("Rollback applied plan", role: .destructive) {
                            rollback(siteID: receipt.siteID, receipt: receipt)
                        }
                    }
                }
                if let selectedID {
                    ControlGroup {
                        Button("Start preview") { startPreview(siteID: selectedID) }
                        Button("Stop preview") { stopPreview(siteID: selectedID) }
                        Button("Archive recoverably", role: .destructive) {
                            archive(siteID: selectedID)
                        }
                    }
                    .disabled(working || pendingPlan != nil)
                    LabeledContent("Preview") {
                        Text(previewStatus.url ?? previewStatus.state.rawValue)
                    }
                }
                if let receipt = lastArchiveReceipt {
                    GroupBox("Recoverable archive receipt") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Digest: \(receipt.archiveDigest)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Restore archived site") { restore(receipt) }
                                .disabled(working)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let plan = pendingPlan {
                    GroupBox("Awaiting operator approval") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(plan.summary).font(.headline)
                            Text("Digest: \(plan.planDigest)")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("\(plan.changes.count) operations · \(plan.totalWriteBytes) write bytes · expires \(plan.expiresAt.formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(plan.changes) { change in
                                Text("\(change.kind.rawValue.uppercased())  \(change.path)  \(change.byteCount) B")
                                    .font(.system(.caption, design: .monospaced))
                            }
                            HStack {
                                Button("Approve exact digest") { approve(plan) }.buttonStyle(.borderedProminent)
                                Button("Reject", role: .destructive) { reject(plan) }
                            }.disabled(working)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                Text("Generation events").font(.headline)
                List(Array(events.enumerated()), id: \.offset) { _, event in
                    Text(eventLabel(event)).font(.system(.caption, design: .monospaced))
                }
            }.frame(minWidth: 480).padding()
        }
        .navigationTitle("Quasar")
        .task { refresh() }
        .onChange(of: selectedID) { _, _ in loadEvents(); loadPendingPlan(); loadPreviewStatus() }
    }

    private func refresh() {
        guard let service = engine.quasarService else { error = engine.quasarInitializationError ?? "Quasar unavailable"; return }
        Task {
            sites = await service.listSites()
            discordProposals = await service.pendingDiscordProposals()
        }
    }

    private func create() {
        guard let service = engine.quasarService else { return }
        working = true; error = nil
        Task {
            do {
                let site = try await service.create(name: name, prompt: prompt)
                selectedID = site.id; name = ""; prompt = ""; refresh(); pollEvents(siteID: site.id)
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func loadEvents() {
        guard let id = selectedID, let service = engine.quasarService else { events = []; return }
        Task { if let page = try? await service.events(id: id, since: 0) { events = page.events } }
    }

    private func loadPendingPlan() {
        guard let id = selectedID, let service = engine.quasarService else { pendingPlan = nil; return }
        Task { pendingPlan = try? await service.pendingPlan(id: id) }
    }

    private func loadPreviewStatus() {
        guard let id = selectedID, let service = engine.quasarService else {
            previewStatus = PreviewStatus()
            return
        }
        Task { previewStatus = (try? await service.previewStatus(id: id)) ?? PreviewStatus() }
    }

    private func pollEvents(siteID: String) {
        Task {
            var cursor = 0
            for _ in 0..<240 {
                guard let service = engine.quasarService,
                      let page = try? await service.events(id: siteID, since: cursor) else { return }
                if !page.events.isEmpty { events.append(contentsOf: page.events); cursor = page.next }
                if page.events.contains(where: { $0.type == .plan }) {
                    pendingPlan = try? await service.pendingPlan(id: siteID)
                    refresh()
                    return
                }
                if page.events.contains(where: { $0.type == .done || $0.type == .error }) { refresh(); return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func approve(_ plan: QuasarMutationPreview) {
        guard let service = engine.quasarService else { return }
        working = true; error = nil
        Task {
            do {
                lastMutationReceipt = try await service.approve(id: plan.siteID, planDigest: plan.planDigest)
                pendingPlan = nil
                loadEvents()
                refresh()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func reject(_ plan: QuasarMutationPreview) {
        guard let service = engine.quasarService else { return }
        working = true; error = nil
        Task {
            do {
                try await service.reject(id: plan.siteID)
                pendingPlan = nil
                loadEvents()
                refresh()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func approveDiscord(_ proposal: QuasarProposal) {
        working = true; error = nil
        Task {
            do {
                _ = try await engine.approveDiscordQuasarProposal(proposal)
                refresh()
            } catch { self.error = error.localizedDescription; refresh() }
            working = false
        }
    }

    private func rejectDiscord(_ proposal: QuasarProposal) {
        guard let service = engine.quasarService else { return }
        Task { await service.cancelDiscordProposal(id: proposal.id); refresh() }
    }

    private func rollback(siteID: String, receipt: QuasarMutationReceipt) {
        guard let service = engine.quasarService else { return }
        working = true; error = nil
        Task {
            do {
                _ = try await service.rollback(id: siteID, planDigest: receipt.planDigest)
                lastMutationReceipt = nil
                refresh()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func startPreview(siteID: String) {
        guard let service = engine.quasarService else { return }
        working = true; error = nil
        Task {
            do { previewStatus = try await service.startPreview(id: siteID) }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func stopPreview(siteID: String) {
        guard let service = engine.quasarService else { return }
        working = true; error = nil
        Task {
            do { previewStatus = try await service.stopPreview(id: siteID) }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func archive(siteID: String) {
        guard let service = engine.quasarService else { return }
        working = true; error = nil
        Task {
            do {
                lastArchiveReceipt = try await service.archive(id: siteID)
                selectedID = nil
                pendingPlan = nil
                events = []
                previewStatus = PreviewStatus()
                refresh()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func restore(_ receipt: QuasarArchiveReceipt) {
        guard let service = engine.quasarService else { return }
        working = true; error = nil
        Task {
            do {
                let restored = try await service.restore(receipt)
                lastArchiveReceipt = nil
                selectedID = restored.id
                refresh()
                loadEvents()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func eventLabel(_ event: GenerationEvent) -> String {
        switch event.type {
        case .text: return event.text ?? "text"
        case .tool: return "\(event.name?.rawValue ?? "tool") \(event.path ?? "")"
        case .plan: return "plan awaiting approval: \(event.text ?? "missing digest")"
        case .done: return "done"
        case .error: return "error: \(event.message ?? "unknown")"
        }
    }
}
