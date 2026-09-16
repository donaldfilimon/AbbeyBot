import SwiftUI
import AbbeyCore

struct ConfirmationSheetView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let request: ConfirmationGate.PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Confirm \(kindTitle)", systemImage: "exclamationmark.shield.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)
                .accessibilityAddTraits(.isHeader)

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Target user").foregroundStyle(.secondary)
                    Text(request.targetUserId)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Guild").foregroundStyle(.secondary)
                    Text(request.guildId)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Reason").foregroundStyle(.secondary)
                    Text(request.reason)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Requested").foregroundStyle(.secondary)
                    Text(request.requestedAt, style: .relative)
                }
            }

            Text("Kick and ban always need an explicit OK; purge needs one while confirmation is enabled in Settings. Cancel stops this from running.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel) {
                    Task {
                        await engine.confirmationGate.cancel(request.id)
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Confirm \(kindTitle)", role: .destructive) {
                    Task {
                        await engine.confirmationGate.confirm(request.id)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 220)
        .onDisappear {
            // Safety net if the sheet is torn down without Confirm/Cancel (e.g. window
            // close). `cancel` is a no-op once the continuation is already resumed.
            Task { await engine.confirmationGate.cancel(request.id) }
        }
    }

    private var kindTitle: String {
        switch request.kind {
        case .purge: return "Purge"
        case .kick: return "Kick"
        case .ban: return "Ban"
        }
    }
}
