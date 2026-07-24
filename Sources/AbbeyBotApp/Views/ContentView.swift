import SwiftUI
import AbbeyCore

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case discord = "Discord"
    case users = "Users"
    case channels = "Channels"
    case messages = "Messages"
    case personas = "Personas"
    case equity = "Equity Research"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .discord: return "bubble.left.and.bubble.right.fill"
        case .users: return "person.2"
        case .channels: return "number"
        case .messages: return "bubble.left.and.bubble.right"
        case .personas: return "sparkles"
        case .equity: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct ContentView: View {
    @Environment(AbbeyEngine.self) private var engine
    @State private var selection: SidebarSection? = .dashboard
    @State private var pendingConfirmation: ConfirmationGate.PendingRequest?

    var body: some View {
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
            case .personas:
                PersonaSwitcherView()
            case .equity:
                EquityResearchView()
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
