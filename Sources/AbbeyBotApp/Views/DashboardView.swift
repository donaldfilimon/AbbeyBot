import SwiftUI
import SwiftData
import AbbeyCore

struct DashboardView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Query private var messages: [GuildMessage]
    @Query private var users: [UserMemory]
    @Query(sort: \InteractionLog.createdAt, order: .reverse) private var interactions: [InteractionLog]

    @State private var draftChannelId = "general"
    @State private var draftGuildId = "dev-guild"
    @State private var draftAuthorId = "donald"
    @State private var draftContent = ""
    @State private var isIngesting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                    MetricCard(title: "Messages (all-time)", value: "\(messages.count)")
                    MetricCard(title: "Users tracked", value: "\(users.count)")
                    MetricCard(title: "Interactions", value: "\(interactions.count)")
                    MetricCard(title: "Messages this session", value: "\(engine.metrics.messagesIngestedThisSession)")
                    MetricCard(title: "Reputation events this session", value: "\(engine.metrics.reputationEventsThisSession)")
                    MetricCard(title: "Inference calls", value: "\(engine.metrics.totalInferenceCalls)")
                    MetricCard(title: "Inference failures", value: "\(engine.metrics.totalInferenceFailures)")
                    MetricCard(title: "Destructive confirmed", value: "\(engine.metrics.destructiveActionsConfirmed)")
                    MetricCard(title: "Destructive cancelled", value: "\(engine.metrics.destructiveActionsCancelled)")
                    MetricCard(title: "Live Discord ingests", value: "\(engine.liveIngestCount)")
                    MetricCard(title: "Discord state", value: engine.discordState.displayName)
                    if let action = engine.lastDQNAction {
                        MetricCard(title: "Last DQN action", value: dqnLabel(action))
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
                        Text("/\(row.commandName)")
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

            HStack {
                Button {
                    Task {
                        isIngesting = true
                        await engine.ingestMessage(
                            content: draftContent,
                            channelId: draftChannelId,
                            guildId: draftGuildId,
                            authorId: draftAuthorId
                        )
                        draftContent = ""
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

    private func dqnLabel(_ action: Int) -> String {
        switch action {
        case 0: return "0 · reply"
        case 1: return "1 · hold"
        case 2: return "2 · escalate"
        default: return "\(action)"
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }
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
