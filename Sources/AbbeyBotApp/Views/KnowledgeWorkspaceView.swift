import AbbeyCore
import SwiftUI

struct KnowledgeWorkspaceView: View {
    @Environment(AbbeyEngine.self) private var engine
    @State private var query = ""
    @State private var hits: [KnowledgeHit] = []
    @State private var isSearching = false
    @State private var isRefreshing = false
    @State private var reviewedDigest = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Signed snapshot") {
                VStack(alignment: .leading, spacing: 8) {
                    if let status = engine.knowledgeSnapshotStatus {
                        Text("Format \(status.formatVersion) · \(status.entryCount) allowlisted documents")
                        Text("Digest: \(status.aggregateDigest)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    } else {
                        Text("Snapshot status unavailable").foregroundStyle(.red)
                    }
                    Button("Stage refresh and drift report") {
                        isRefreshing = true
                        Task { await engine.stageKnowledgeRefresh(); isRefreshing = false }
                    }.disabled(isRefreshing)
                    if isRefreshing { ProgressView().controlSize(.small) }
                    if let candidate = engine.knowledgeRefreshCandidate {
                        Divider()
                        Text("Candidate \(candidate.digest)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        driftRows("Additions", candidate.report.additions)
                        driftRows("Removals", candidate.report.removals)
                        driftRows("Changed digests", candidate.report.changedDigests)
                        driftRows("Classification changes", candidate.report.classificationChanges)
                        driftRows("Unresolved drift", candidate.report.unresolvedDrift)
                        TextField("Paste the full reviewed candidate digest", text: $reviewedDigest).textFieldStyle(.roundedBorder)
                        Button("Sign and apply reviewed snapshot") {
                            isRefreshing = true
                            Task { await engine.applyKnowledgeRefresh(reviewedDigest: reviewedDigest); reviewedDigest = ""; isRefreshing = false }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(reviewedDigest != candidate.digest || isRefreshing)
                    }
                    if let error = engine.knowledgeRefreshError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField("Search signed Abbey ecosystem knowledge", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Search") { search() }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            Text("Results are a disposable projection of signed, provenance-tagged sources. They do not modify WDBX or guild memory.")
                .font(.caption).foregroundStyle(.secondary)
            if let initializationError = engine.knowledgeInitializationError {
                Label(initializationError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            if hits.isEmpty {
                ContentUnavailableView("No evidence selected", systemImage: "books.vertical", description: Text("Search terms must match the verified snapshot and caller scope."))
            } else {
                List(hits) { hit in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(hit.title).font(.headline); Spacer(); Text(hit.provenance.rawValue).font(.caption).foregroundStyle(.secondary) }
                        Text(hit.excerpt).textSelection(.enabled)
                        Text("\(hit.sourceRepository) @ \(hit.sourceRevision.prefix(12)) · \(hit.sourcePath) · \(hit.contentDigest.prefix(12))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .navigationTitle("Knowledge")
    }

    @ViewBuilder
    private func driftRows(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            Text("\(title): \(values.joined(separator: ", "))").font(.caption).textSelection(.enabled)
        }
    }

    private func search() {
        isSearching = true
        Task {
            hits = await engine.searchKnowledge(query)
            isSearching = false
        }
    }
}
