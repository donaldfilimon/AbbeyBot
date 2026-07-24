import SwiftUI
import AbbeyCore

struct SettingsView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Bindable private var config = AppConfig.shared

    var body: some View {
        Form {
            Section("Operating mode") {
                Picker("ABBEY_OPERATING_MODE", selection: $config.operatingMode) {
                    ForEach(OperatingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Text(config.operatingMode == .standalone
                     ? "Local SwiftData only — no Discord gateway."
                     : "Live Discord via DiscordBM gateway when connected from the Discord tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Inference") {
                Picker("ABBEY_INFERENCE_MODE", selection: $config.inferenceMode) {
                    ForEach(InferenceMode.allCases) { mode in
                        Text(label(for: mode)).tag(mode)
                    }
                }
                if config.inferenceMode == .remoteCompatible {
                    TextField("ABBEY_REMOTE_ENDPOINT", text: $config.remoteEndpoint, prompt: Text("https://your-endpoint/v1/chat/completions"))
                        .textFieldStyle(.roundedBorder)
                }
                if config.inferenceMode == .onDevice {
                    Text("Falls back to the deterministic floor automatically if Foundation Models is unavailable on this machine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Timing") {
                LabeledContent("ABBEY_REPLY_COOLDOWN_SECONDS") {
                    Stepper(value: $config.replyCooldownSeconds, in: 0...120, step: 1) {
                        Text("\(Int(config.replyCooldownSeconds)) s")
                    }
                }
                LabeledContent("ABBEY_MEMORY_CONSOLIDATION_INTERVAL_MIN") {
                    Stepper(value: $config.memoryConsolidationIntervalMinutes, in: 1...240, step: 1) {
                        Text("\(Int(config.memoryConsolidationIntervalMinutes)) min")
                    }
                }
                Button("Restart consolidation loop with current interval") {
                    Task { await engine.scheduler.start() }
                }
            }

            Section("Reputation") {
                LabeledContent("ABBEY_REPUTATION_DECAY") {
                    Slider(value: $config.reputationDecay, in: 0.5...0.99, step: 0.01) {
                        Text("Decay")
                    }
                }
                Text("EMA weight applied to the existing score — higher means reputation moves more slowly. Current: \(String(format: "%.2f", config.reputationDecay))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Safety") {
                Toggle("ABBEY_CONFIRMATION_REQUIRED", isOn: $config.confirmationRequiredForDestructiveActions)
                Text("Gates purge/kick/ban behind an explicit confirmation sheet. Turning this off means destructive actions execute immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Modules") {
                Toggle("ABBEY_EQUITY_MODULE_ENABLED", isOn: $config.equityModuleEnabled)
                Text("Synthetic-instrument idea generation. Not investment advice — see the Equity Research tab's disclaimer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .navigationTitle("Settings")
    }

    private func label(for mode: InferenceMode) -> String {
        switch mode {
        case .deterministicFloor: return "Deterministic floor (rule-based, no model)"
        case .onDevice: return "On-device (Foundation Models)"
        case .remoteCompatible: return "Remote (OpenAI-compatible endpoint)"
        }
    }
}
