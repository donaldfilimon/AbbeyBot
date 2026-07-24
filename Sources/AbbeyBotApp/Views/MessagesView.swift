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

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter by channel ID", text: $channelFilter)
                .textFieldStyle(.roundedBorder)
                .padding()

            List(filtered) { message in
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
        .navigationTitle("Messages")
    }
}
