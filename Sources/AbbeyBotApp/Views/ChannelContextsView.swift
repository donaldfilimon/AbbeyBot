import SwiftUI
import SwiftData
import AbbeyCore

struct ChannelContextsView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChannelContext.updatedAt, order: .reverse) private var channels: [ChannelContext]
    @State private var newChannelId = ""
    @State private var newGuildId = ""
    @State private var operationError: String?

    var body: some View {
        VStack {
            if channels.isEmpty {
                ContentUnavailableView(
                    "No channels tracked",
                    systemImage: "number",
                    description: Text("Add a channel below, or ingest a message to create context automatically.")
                )
            } else {
                List(channels) { channel in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("#\(channel.channelId)").font(.headline)
                            Spacer()
                            Text("\(channel.messageCount) msgs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(channel.summary.isEmpty ? "No summary yet." : channel.summary)
                            .font(.caption)
                            .foregroundStyle(channel.summary.isEmpty ? .secondary : .primary)
                            .lineLimit(6)
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            HStack {
                TextField("Channel ID", text: $newChannelId)
                TextField("Guild ID", text: $newGuildId)
                Button("Track channel") {
                    let context = ChannelContext(channelId: newChannelId, guildId: newGuildId)
                    modelContext.insert(context)
                    do {
                        try modelContext.save()
                        operationError = nil
                        newChannelId = ""
                        newGuildId = ""
                    } catch {
                        modelContext.rollback()
                        operationError = OperatorFacingError.message(error)
                    }
                }
                .disabled(newChannelId.isEmpty || newGuildId.isEmpty)

                Button("Consolidate now") {
                    Task {
                        do {
                            try await engine.scheduler.consolidateAllChannels()
                            operationError = nil
                        } catch {
                            operationError = OperatorFacingError.message(error)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding()

            if let operationError {
                Label(operationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .navigationTitle("Channels")
    }
}
