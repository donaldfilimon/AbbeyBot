import SwiftUI
import SwiftData
import AbbeyCore

struct UsersView: View {
    @Query private var users: [UserMemory]
    @State private var selectedUser: UserMemory?

    init() {
        var descriptor = FetchDescriptor<UserMemory>(
            sortBy: [SortDescriptor(\UserMemory.reputation, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        _users = Query(descriptor)
    }

    private var sections: [(guildId: String, users: [UserMemory])] {
        let grouped = Dictionary(grouping: users, by: \.guildId)
        return grouped.keys.sorted().map { key in
            (guildId: key, users: grouped[key] ?? [])
        }
    }

    var body: some View {
        // HSplitView (not NavigationSplitView) — parent ContentView already owns the sidebar split.
        HSplitView {
            Group {
                if users.isEmpty {
                    ContentUnavailableView(
                        "No users tracked",
                        systemImage: "person.2",
                        description: Text("Ingest a message or connect Discord to populate reputation.")
                    )
                } else {
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
                }
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

            Group {
                if let user = selectedUser {
                    UserDetailView(user: user)
                } else {
                    ContentUnavailableView("Select a user", systemImage: "person")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Users")
    }
}

private struct UserDetailView: View {
    @Environment(AbbeyEngine.self) private var engine
    let user: UserMemory
    @Query private var events: [ReputationEvent]
    @State private var reason = ""

    init(user: UserMemory) {
        self.user = user
        let userId = user.discordUserId
        let guildId = user.guildId
        var descriptor = FetchDescriptor<ReputationEvent>(
            predicate: #Predicate { $0.userId == userId && $0.guildId == guildId },
            sortBy: [SortDescriptor(\ReputationEvent.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 25
        _events = Query(descriptor)
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
