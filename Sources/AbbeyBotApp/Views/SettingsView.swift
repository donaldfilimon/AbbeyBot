import SwiftUI
import AbbeyCore

struct SettingsView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Bindable private var config = AppConfig.shared
    private var syncStatus = SyncStatus.shared

    var body: some View {
        Form {
            Section {
                Picker("Operating mode", selection: $config.operatingMode) {
                    Text("Standalone").tag(OperatingMode.standalone)
                    Text("Live Discord").tag(OperatingMode.liveDiscord)
                }
                Text(config.operatingMode == .standalone
                     ? "Local SwiftData only — no Discord gateway. Env: ABBEY_OPERATING_MODE"
                     : "Live Discord via DiscordBM gateway when connected from the Discord tab. Env: ABBEY_OPERATING_MODE")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Operating mode")
            }

            Section("Inference") {
                Picker("Inference mode", selection: $config.inferenceMode) {
                    ForEach(InferenceMode.allCases) { mode in
                        Text(label(for: mode)).tag(mode)
                    }
                }
                Text("Env: ABBEY_INFERENCE_MODE")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if config.inferenceMode == .remoteCompatible {
                    TextField("Remote endpoint", text: $config.remoteEndpoint, prompt: Text("https://your-endpoint/v1/chat/completions"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Model identity", text: $config.remoteModel)
                    SecureField("Provider bearer token", text: $config.remoteAPIToken)
                    Text("Env: ABBEY_REMOTE_ENDPOINT")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if config.inferenceMode == .onDevice {
                    Text("Falls back to the deterministic floor automatically if Foundation Models is unavailable on this machine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Quasar service") {
                Picker("Backend (after restart)", selection: $config.quasarBackend) {
                    Text("Local service").tag(QuasarBackend.local)
                    Text("Remote service").tag(QuasarBackend.remote)
                }
                TextField("Quasar endpoint", text: $config.quasarEndpoint)
                SecureField("Dedicated Quasar API token", text: $config.quasarAPIToken)
                Text("Restart Abbey to apply backend settings. Quasar credentials are stored in Keychain and are separate from sync settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Timing") {
                LabeledContent("Reply cooldown") {
                    Stepper(value: $config.replyCooldownSeconds, in: 0...120, step: 1) {
                        Text("\(Int(config.replyCooldownSeconds)) s")
                    }
                }
                Text("Env: ABBEY_REPLY_COOLDOWN_SECONDS")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                LabeledContent("Memory consolidation") {
                    Stepper(value: $config.memoryConsolidationIntervalMinutes, in: 1...240, step: 1) {
                        Text("\(Int(config.memoryConsolidationIntervalMinutes)) min")
                    }
                }
                Text("Env: ABBEY_MEMORY_CONSOLIDATION_INTERVAL_MIN")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Restart consolidation loop with current interval") {
                    Task { await engine.scheduler.start() }
                }
            }

            Section("Reputation") {
                LabeledContent("Decay") {
                    Slider(value: $config.reputationDecay, in: 0.5...0.99, step: 0.01) {
                        Text("Decay")
                    }
                }
                Text("EMA weight on the existing score — higher means reputation moves more slowly. Current: \(String(format: "%.2f", config.reputationDecay)). Env: ABBEY_REPUTATION_DECAY")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Safety") {
                Toggle("Require confirmation for destructive actions", isOn: $config.confirmationRequiredForDestructiveActions)
                Text("Gates purge/kick/ban behind an explicit confirmation sheet. Env: ABBEY_CONFIRMATION_REQUIRED")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Modules") {
                Toggle("Equity research module", isOn: $config.equityModuleEnabled)
                Text("Synthetic-instrument idea generation. Not investment advice — see the Equity Research tab. Env: ABBEY_EQUITY_MODULE_ENABLED")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Server sync") {
                TextField("Server URL", text: $config.syncServerURL, prompt: Text("https://your-abbeyserver-host"))
                    .textFieldStyle(.roundedBorder)
                Text("Env: ABBEY_SYNC_SERVER_URL")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                SecureField("API token (optional)", text: $config.syncAPIToken)
                Text("Env: ABBEY_SYNC_API_TOKEN")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(config.syncServerURL.isEmpty
                     ? "Sync is off — local SwiftData stays the only source of truth."
                     : "Push mirrors ingest/remember/forget; pull upserts users/channels and inserts missing messages. Failures never block local writes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !config.syncServerURL.isEmpty {
                    Button("Pull now") {
                        Task { await engine.pullFromServer() }
                    }
                    .disabled(syncStatus.isPulling)
                    syncStatusSummaryLines
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var syncStatusSummaryLines: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            if syncStatus.lastPullError == nil {
                Text(syncStatus.pullSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(syncStatus.pullSummary)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if syncStatus.lastError == nil {
                Text(syncStatus.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(syncStatus.summary)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func label(for mode: InferenceMode) -> String {
        switch mode {
        case .deterministicFloor: return "Deterministic floor (rule-based, no model)"
        case .onDevice: return "On-device (Foundation Models)"
        case .remoteCompatible: return "Remote (OpenAI-compatible endpoint)"
        }
    }
}
