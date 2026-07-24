import SwiftUI
import SwiftData
import AbbeyCore

struct MessagesView: View {
    @Query(sort: \GuildMessage.createdAt, order: .reverse) private var messages: [GuildMessage]
    @State private var channelFilter = ""

    private var filtered: [GuildMessage] {
        guard !channelFilter.isEmpty else { return messages }
        return messages.filter { $0.channelId.localizedCaseInsensitiveContains(channelFilter) }
    }

    private var sections: [(guildId: String, messages: [GuildMessage])] {
        let grouped = Dictionary(grouping: filtered, by: \.guildId)
        return grouped.keys.sorted().map { key in
            (guildId: key, messages: grouped[key] ?? [])
        }
    }

    var body: some View {
        Group {
            if messages.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "text.bubble",
                    description: Text("Simulate an ingest on the Dashboard or connect Discord.")
                )
            } else {
                VStack(spacing: 0) {
                    TextField("Filter by channel ID", text: $channelFilter)
                        .textFieldStyle(.roundedBorder)
                        .padding()

                    if filtered.isEmpty {
                        ContentUnavailableView(
                            "No matches",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("No messages match “\(channelFilter)”.")
                        )
                    } else {
                        List {
                            ForEach(sections, id: \.guildId) { section in
                                Section(section.guildId) {
                                    ForEach(section.messages) { message in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(message.authorId).font(.headline)
                                                Text("#\(message.channelId)").font(.caption).foregroundStyle(.secondary)
                                                Spacer()
                                                Text(message.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Text(message.content)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Messages")
    }
}
