import SwiftUI
import SwiftData
import AbbeyCore

/// Root entry point for AbbeyBot desktop — SwiftUI + SwiftData + DiscordBM.
@main
struct AbbeyBotApp: App {
    @State private var engine: AbbeyEngine

    init() {
        let boot = Self.makeModelContainer()
        _engine = State(initialValue: AbbeyEngine(modelContainer: boot.container, storeDegraded: boot.degraded))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
        }
        .modelContainer(engine.modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environment(engine)
        }
    }

    private static func makeModelContainer() -> (container: ModelContainer, degraded: Bool) {
        let schema = Schema([
            GuildMessage.self,
            UserMemory.self,
            ChannelContext.self,
            ReputationEvent.self,
            InteractionLog.self,
            EquityIdea.self
        ])
        let configuration = ModelConfiguration(
            "AbbeyBotStore",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return (container, false)
        } catch {
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            do {
                let container = try ModelContainer(for: schema, configurations: [fallback])
                return (container, true)
            } catch {
                fatalError("AbbeyBot: could not construct any ModelContainer: \(error)")
            }
        }
    }
}
