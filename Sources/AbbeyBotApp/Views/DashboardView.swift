import SwiftUI
import SwiftData
import AbbeyCore

struct DashboardView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Environment(\.modelContext) private var modelContext
    @Query private var interactions: [InteractionLog]

    @State private var draftChannelId = "general"
    @State private var draftGuildId = "dev-guild"
    @State private var draftAuthorId = "donald"
    @State private var draftContent = ""
    @State private var isIngesting = false
    @State private var ingestError: String?
    @State private var counts = DashboardCounts()

    init() {
        var descriptor = FetchDescriptor<InteractionLog>(
            sortBy: [SortDescriptor(\InteractionLog.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 5
        _interactions = Query(descriptor)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                    MetricCard(title: "Messages (all-time)", value: "\(counts.messages)")
                    MetricCard(title: "Users tracked", value: "\(counts.users)")
                    MetricCard(title: "Interactions", value: "\(counts.interactions)")
                    MetricCard(title: "Messages this session", value: "\(engine.metrics.messagesIngestedThisSession)")
                    MetricCard(title: "Reputation events this session", value: "\(engine.metrics.reputationEventsThisSession)")
                    MetricCard(title: "Inference calls", value: "\(engine.metrics.totalInferenceCalls)")
                    MetricCard(title: "Inference failures", value: "\(engine.metrics.totalInferenceFailures)")
                    MetricCard(title: "Destructive confirmed", value: "\(engine.metrics.destructiveActionsConfirmed)")
                    MetricCard(title: "Destructive cancelled", value: "\(engine.metrics.destructiveActionsCancelled)")
                    MetricCard(title: "Live Discord ingests", value: "\(engine.liveIngestCount)")
                    MetricCard(title: "Discord state", value: engine.discordState.displayName)
                    if let action = engine.lastDQNAction {
                        MetricCard(title: "Last DQN strategy", value: dqnLabel(action, strategy: engine.lastStrategy))
                    }
                    MetricCard(
                        title: "WDBX records",
                        value: "\(engine.wdbxStore?.recordCount ?? 0)"
                    )
                    MetricCard(title: "NN accel", value: NeuralMath.accelerationBackend)
                    if engine.config.inferenceMode == .onDevice {
                        MetricCard(
                            title: "Foundation Models",
                            value: FoundationModelsProvider.availabilitySummary
                        )
                    }
                    if let consolidated = engine.metrics.lastConsolidationAt {
                        MetricCard(title: "Last consolidation", value: relative(consolidated))
                    }
                }

                if engine.metrics.storeDegraded {
                    Label("Local store fell back to in-memory — data will not persist across launches.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                if let failure = engine.metrics.lastInferenceFailureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                recentInteractions

                Divider()

                ingestForm
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .navigationSubtitle(
            "Mode: \(operatingModeLabel) · Inference: \(inferenceModeLabel)"
        )
        .task(id: engine.metrics.messagesIngestedThisSession) {
            refreshCounts()
        }
    }

    private var operatingModeLabel: String {
        switch engine.config.operatingMode {
        case .standalone: return "Standalone"
        case .liveDiscord: return "Live Discord"
        }
    }

    private var inferenceModeLabel: String {
        switch engine.config.inferenceMode {
        case .deterministicFloor: return "Deterministic floor"
        case .onDevice: return "On-device"
        case .remoteCompatible: return "Remote"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let event = engine.lastEvent {
                Text("Last event: \(event.displayDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Waiting for activity…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var recentInteractions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent interactions").font(.headline)
            if interactions.isEmpty {
                Text("No slash-command interactions logged yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(interactions.prefix(5)) { row in
                    HStack {
                        Image(systemName: row.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(row.succeeded ? .green : .red)
                            .font(.caption)
                        Text(InteractionCommandLabel.format(row.commandName))
                            .font(.caption.monospaced())
                        Text(row.userId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var ingestForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Simulate a message").font(.headline)
            Text("Tip: include “remember …” to store a user fact; “be aviva/abi/abbey” to switch persona.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Channel ID", text: $draftChannelId)
                TextField("Guild ID", text: $draftGuildId)
                TextField("Author ID", text: $draftAuthorId)
            }
            .textFieldStyle(.roundedBorder)

            TextField("Message content", text: $draftContent, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            if let ingestError {
                Label(ingestError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    Task {
                        isIngesting = true
                        ingestError = nil
                        let outcome = await engine.ingestMessage(
                            content: draftContent,
                            channelId: draftChannelId,
                            guildId: draftGuildId,
                            authorId: draftAuthorId
                        )
                        if case .inserted = outcome {
                            draftContent = ""
                            refreshCounts()
                        } else {
                            ingestError = "The message was not persisted, so no learning or reply was performed."
                        }
                        isIngesting = false
                    }
                } label: {
                    if isIngesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Ingest")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isIngesting)

                Spacer()
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func dqnLabel(_ action: Int, strategy: StrategyAction) -> String {
        "\(action) · \(strategy.label)"
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    @MainActor
    private func refreshCounts() {
        counts = DashboardCounts(
            messages: (try? modelContext.fetchCount(FetchDescriptor<GuildMessage>())) ?? 0,
            users: (try? modelContext.fetchCount(FetchDescriptor<UserMemory>())) ?? 0,
            interactions: (try? modelContext.fetchCount(FetchDescriptor<InteractionLog>())) ?? 0
        )
    }
}

private struct DashboardCounts: Equatable {
    var messages = 0
    var users = 0
    var interactions = 0
}

private struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(.title, design: .rounded, weight: .semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}
