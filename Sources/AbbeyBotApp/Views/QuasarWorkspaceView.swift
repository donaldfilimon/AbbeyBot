import AbbeyQuasarKit
import SwiftUI
import WebKit

struct QuasarWorkspaceView: View {
    @Environment(AbbeyEngine.self) private var engine
    @State private var model: QuasarWorkspaceModel?

    var body: some View {
        Group {
            if let model { QuasarWorkspaceContent(model: model) }
            else { ContentUnavailableView("Quasar unavailable", systemImage: "network.slash", description: Text(engine.quasarInitializationError ?? "The selected service could not be initialized.")) }
        }
        .navigationTitle("Quasar")
        .task {
            if model == nil, let client = engine.quasarWorkspaceClient { model = QuasarWorkspaceModel(client: client) }
        }
    }
}

private struct QuasarWorkspaceContent: View {
    @Bindable var model: QuasarWorkspaceModel
    @State private var showsPreview = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                Text("Sites").font(.headline)
                List(model.sites, selection: $model.selectedID) { site in
                    VStack(alignment: .leading) {
                        Text(site.name)
                        Text(site.status.rawValue).font(.caption).foregroundStyle(.secondary)
                    }.tag(site.id)
                }
                Button("Refresh") { Task { await model.refresh(); await model.loadSelection() } }
                if !model.archives.isEmpty {
                    Text("Recoverable archives").font(.headline)
                    ForEach(model.archives, id: \.archiveDigest) { receipt in
                        Button("Restore \(receipt.siteID)") { perform(.restore(receipt)) }
                            .lineLimit(1).disabled(model.working || model.uncertainOutcome)
                    }
                }
            }.frame(minWidth: 210, idealWidth: 240).padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if model.uncertainOutcome {
                        Button("I reviewed the authoritative history") { Task { await model.acknowledgeReconciliation() } }
                    }
                    Text("Plan a site change").font(.title2.bold())
                    TextField("New site name", text: $model.name).textFieldStyle(.roundedBorder).disabled(model.working)
                    TextEditor(text: $model.prompt).frame(height: 110).disabled(model.working)
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
                    HStack {
                        Button("Create site") { perform(.create) }.disabled(model.name.isEmpty || model.prompt.isEmpty)
                        Button("Edit selected site") { perform(.edit) }.disabled(model.selectedID == nil || model.prompt.isEmpty)
                        if model.working { ProgressView().controlSize(.small) }
                    }.disabled(disabled)
                    Text("Review the complete file changes before approving. Dependency installation and preview execution each require an explicit action.")
                        .font(.caption).foregroundStyle(.secondary)

                    if model.selectedID != nil {
                        HStack {
                            Button("Prepare dependencies") { perform(.prepare) }
                            Button("Start preview") { perform(.startPreview) }
                            Button("Stop preview") { perform(.stopPreview) }
                            Button("Open / renew preview") {
                                Task { await model.perform(.openPreview); showsPreview = model.previewURL != nil }
                            }.disabled(model.preview.state != .running)
                        }.disabled(disabled || model.review != nil)
                        Text("Preview: \(model.preview.state.rawValue)").font(.caption)
                        Button("Archive recoverably", role: .destructive) { perform(.archive) }
                            .disabled(disabled || model.review != nil)
                    }
                    if let review = model.review {
                        GroupBox("Review exact proposed changes") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(review.summary).font(.headline)
                                Text("Digest: \(review.planDigest)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Text("Expires \(review.expiresAt.formatted()) · \(review.files.count) files")
                                ForEach(review.files, id: \.path) { file in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("\(file.kind.rawValue.uppercased()) \(file.path)").font(.headline)
                                        content("Before", text: file.before)
                                        content("After", text: file.after)
                                    }
                                }
                                HStack {
                                    Button("Approve exact changes") { perform(.approve) }.buttonStyle(.borderedProminent)
                                    Button("Reject", role: .destructive) { perform(.reject) }
                                }.disabled(disabled || review.expiresAt <= Date())
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !model.proposals.isEmpty {
                        Text("Discord proposals").font(.title2.bold())
                        ForEach(model.proposals) { proposal in
                            GroupBox(proposal.summary) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(proposal.impact)
                                    Text("Initiator \(proposal.facts.initiatorID) · guild \(proposal.facts.guildID) · expires \(proposal.expiresAt.formatted())").font(.caption)
                                    Text("The owning service checks current permissions and policy. Create/edit approval starts planning; file changes require a separate review.").font(.caption)
                                    HStack {
                                        Button("Approve after revalidation") { perform(.approveProposal(proposal.id, proposal.digest)) }
                                        Button("Reject", role: .destructive) { perform(.rejectProposal(proposal.id)) }
                                    }.disabled(disabled)
                                }
                            }
                        }
                    }
                    Text("Recovery history").font(.headline)
                    ForEach(model.history, id: \.id) { record in
                        VStack(alignment: .leading) {
                            Text("\(record.kind.rawValue) · \(record.status.rawValue) · \(record.startedAt.formatted())")
                            if let problem = record.problem { Text(problem.message).foregroundStyle(.red) }
                            if record.status == .uncertain {
                                Text("Inspect the site and snapshots, then record which outcome you verified. This records your recovery decision; it does not replay the operation.")
                                HStack {
                                    Button("Verified applied") { Task { await model.reconcile(recordID: record.id, resolution: .confirmedApplied) } }
                                    Button("Verified not applied") { Task { await model.reconcile(recordID: record.id, resolution: .confirmedNotApplied) } }
                                }.disabled(model.working)
                            }
                            if record.kind == .mutation, record.status == .succeeded, let digest = record.planDigest {
                                Button("Rollback \(digest.prefix(12))", role: .destructive) { perform(.rollback(digest)) }
                                    .disabled(disabled || model.review != nil)
                            }
                        }.font(.caption)
                    }
                    Text("Generation events").font(.headline)
                    ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                        Text(eventLabel(event)).font(.system(.caption, design: .monospaced))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }.frame(minWidth: 600)
        }
        .task { await model.refresh() }
        .task(id: model.selectedID) { await model.observeSelection() }
        .sheet(isPresented: $showsPreview) {
            VStack {
                HStack { Text("Private site preview").font(.headline); Spacer(); Button("Close") { showsPreview = false } }.padding()
                if let url = model.previewURL { QuasarPreviewWebView(url: url).id(url) }
            }.frame(minWidth: 900, minHeight: 650)
        }
    }
    private var disabled: Bool { model.working || model.uncertainOutcome || !model.connected || model.capabilities == nil }
    private func perform(_ action: QuasarWorkspaceModel.Action) { Task { await model.perform(action) } }
    private func content(_ title: String, text: String?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold())
            Text(text ?? "(file absent)")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(.quaternary.opacity(0.3))
        }
    }
    private func eventLabel(_ event: GenerationEvent) -> String {
        switch event.type {
        case .text: return event.text ?? "text"
        case .tool: return "\(event.name?.rawValue ?? "tool") \(event.path ?? "")"
        case .plan: return "plan awaiting approval"
        case .done: return "done"
        case .error: return event.message ?? "generation failed"
        }
    }
}

/// Each preview uses an ephemeral data store, with no operator API bearer token.
/// Navigation stays on its assigned preview origin; external links are not loaded.
private struct QuasarPreviewWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(origin: url) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let origin: URL
        init(origin: URL) { self.origin = origin }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, QuasarEndpointPolicy.sameOrigin(origin, url) else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
}
