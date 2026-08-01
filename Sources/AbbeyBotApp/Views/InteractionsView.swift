import AbbeyCore
import SwiftUI
import SwiftData

struct InteractionsView: View {
    @Query private var interactions: [InteractionLog]

    init() {
        var descriptor = FetchDescriptor<InteractionLog>(
            sortBy: [SortDescriptor(\InteractionLog.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        _interactions = Query(descriptor)
    }

    var body: some View {
        Group {
            if interactions.isEmpty {
                ContentUnavailableView(
                    "No interactions yet",
                    systemImage: "bolt.horizontal",
                    description: Text("Slash-command usage appears here when the bot handles commands.")
                )
            } else {
                List(interactions) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: row.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(row.succeeded ? .green : .red)
                            .accessibilityLabel(row.succeeded ? "Succeeded" : "Failed")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(InteractionCommandLabel.format(row.commandName))
                                .font(.headline.monospaced())
                            Text("\(row.userId) · \(row.guildId)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(row.latencyMs)) ms")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(row.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Interactions")
        .navigationSubtitle("Showing the 500 most recent interaction records")
    }
}
