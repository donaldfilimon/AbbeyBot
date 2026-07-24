import SwiftUI
import AbbeyCore

struct ConfirmationSheetView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let request: ConfirmationGate.PendingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Confirm \(request.kind.rawValue)", systemImage: "exclamationmark.shield.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Target user").foregroundStyle(.secondary)
                    Text(request.targetUserId)
                }
                GridRow {
                    Text("Guild").foregroundStyle(.secondary)
                    Text(request.guildId)
                }
                GridRow {
                    Text("Reason").foregroundStyle(.secondary)
                    Text(request.reason)
                }
                GridRow {
                    Text("Requested").foregroundStyle(.secondary)
                    Text(request.requestedAt, style: .relative)
                }
            }

            Text("This action was routed through ConfirmationGate because ABBEY_CONFIRMATION_REQUIRED is on. Cancelling here stops it from executing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", role: .cancel) {
                    Task {
                        await engine.confirmationGate.cancel(request.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Confirm \(request.kind.rawValue.capitalized)", role: .destructive) {
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
        .frame(minWidth: 420)
        .onDisappear {
            // Safety net if the sheet is torn down without Confirm/Cancel (e.g. window
            // close). `cancel` is a no-op once the continuation is already resumed.
            Task { await engine.confirmationGate.cancel(request.id) }
        }
    }
}
