import SwiftUI
import SwiftData
import AbbeyCore

struct UsersView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Query(sort: \UserMemory.reputation, order: .reverse) private var users: [UserMemory]
    @State private var selectedUser: UserMemory?

    private var sections: [(guildId: String, users: [UserMemory])] {
        let grouped = Dictionary(grouping: users, by: \.guildId)
        return grouped.keys.sorted().map { key in
            (guildId: key, users: grouped[key] ?? [])
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedUser) {
                ForEach(sections, id: \.guildId) { section in
                    Section(section.guildId) {
                        ForEach(section.users) { user in
                            VStack(alignment: .leading) {
                                Text(user.discordUserId).font(.headline)
                                Text("rep: \(String(format: "%.2f", user.reputation))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(user)
                        }
                    }
                }
            }
        } detail: {
            if let user = selectedUser {
                UserDetailView(user: user)
            } else {
                ContentUnavailableView("Select a user", systemImage: "person")
            }
        }
        .navigationTitle("Users")
    }
}

private struct UserDetailView: View {
    @Environment(AbbeyEngine.self) private var engine
    let user: UserMemory
    @Query private var allEvents: [ReputationEvent]
    @State private var reason = ""

    private var events: [ReputationEvent] {
        allEvents
            .filter { $0.userId == user.discordUserId && $0.guildId == user.guildId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(user.discordUserId).font(.largeTitle.bold())
                Text("Guild: \(user.guildId)")
                Text("Reputation: \(String(format: "%.3f", user.reputation))")
                Text("Interactions: \(user.interactionCount)")

                if !user.facts.isEmpty {
                    GroupBox("Facts") {
                        VStack(alignment: .leading) {
                            ForEach(user.facts, id: \.self) { fact in
                                Text("• \(fact)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Reputation history") {
                    if events.isEmpty {
                        Text("No events yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(events.prefix(25)) { event in
                            HStack {
                                Text(event.reason)
                                Spacer()
                                Text(String(format: "%+.3f", event.delta))
                                    .foregroundStyle(event.delta >= 0 ? .green : .red)
                                Text(event.createdAt, style: .relative)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }

                GroupBox("Moderation") {
                    HStack {
                        TextField("Reason", text: $reason)
                            .textFieldStyle(.roundedBorder)
                        Button("Purge", role: .destructive) {
                            requestAction(.purge)
                        }
                        Button("Timeout / Kick", role: .destructive) {
                            requestAction(.kick)
                        }
                        Button("Ban", role: .destructive) {
                            requestAction(.ban)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(user.discordUserId)
    }

    private func requestAction(_ kind: DestructiveAction) {
        let engine = self.engine
        let userId = user.discordUserId
        let guildId = user.guildId
        let reasonText = reason.isEmpty ? "unspecified" : reason
        Task {
            await engine.performLiveModeration(kind, targetUserId: userId, guildId: guildId, reason: reasonText)
        }
    }
}
