import SwiftUI
import AbbeyCore

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case discord = "Discord"
    case users = "Users"
    case channels = "Channels"
    case messages = "Messages"
    case interactions = "Interactions"
    case personas = "Personas"
    case equity = "Equity Research"
    case knowledge = "Knowledge"
    case quasar = "Quasar"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .discord: return "antenna.radiowaves.left.and.right"
        case .users: return "person.2"
        case .channels: return "number"
        case .messages: return "text.bubble"
        case .interactions: return "bolt.horizontal"
        case .personas: return "sparkles"
        case .equity: return "chart.line.uptrend.xyaxis"
        case .knowledge: return "books.vertical"
        case .quasar: return "wand.and.stars"
        }
    }
}

struct ContentView: View {
    @Environment(AbbeyEngine.self) private var engine
    @State private var selection: SidebarSection? = .dashboard
    @State private var pendingConfirmation: ConfirmationGate.PendingRequest?

    var body: some View {
        VStack(spacing: 0) {
            if let startupConfigError = engine.startupConfigError {
                StartupConfigBanner(message: startupConfigError)
            }
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("AbbeyBot")
        } detail: {
            switch selection {
            case .dashboard, .none:
                DashboardView()
            case .discord:
                DiscordView()
            case .users:
                UsersView()
            case .channels:
                ChannelContextsView()
            case .messages:
                MessagesView()
            case .interactions:
                InteractionsView()
            case .personas:
                PersonaSwitcherView()
            case .equity:
                EquityResearchView()
            case .knowledge:
                KnowledgeWorkspaceView()
            case .quasar:
                QuasarWorkspaceView()
            }
        }
        .toolbar {
            DefaultToolbarItem(kind: .sidebarToggle)
        }
        .task {
            await watchForConfirmationRequests()
        }
        .sheet(item: $pendingConfirmation) { request in
            ConfirmationSheetView(request: request)
                .interactiveDismissDisabled()
        }
    }

    /// Event-driven presentation of the confirmation sheet. Pulls the live queue head
    /// from `ConfirmationGate` whenever a destructive-action event arrives — never gates
    /// on `engine.lastEvent`, which is overwritten by every other event.
    private func watchForConfirmationRequests() async {
        let stream = await engine.eventBus.subscribe()
        for await event in stream {
            switch event {
            case .destructiveActionRequested, .destructiveActionConfirmed, .destructiveActionCancelled:
                let queue = await engine.confirmationGate.queue
                pendingConfirmation = queue.first
            default:
                break
            }
        }
    }
}

/// Surfaces a startup configuration problem that would otherwise be invisible.
/// Abbey keeps running in a reduced mode (it will not connect to Discord without a
/// token) so the operator can reach Settings and correct the value.
struct StartupConfigBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Startup configuration needs attention")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                Text("Abbey started without connecting. Open Settings to correct this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Startup configuration needs attention. \(message)")
    }
}
