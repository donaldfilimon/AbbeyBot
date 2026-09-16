import SwiftUI
import SwiftData
import AppKit
import AbbeyCore

/// Public entry for unified `AbbeyEntry` (`swift run` → desktop).
public enum AbbeyDesktopMain {
    @MainActor
    public static func main() {
        AbbeyBotApp.main()
    }
}

/// Desktop SwiftUI + SwiftData app (internal; launched via `AbbeyDesktopMain`).
struct AbbeyBotApp: App {
    @State private var engine: AbbeyEngine
    @State private var didActivate = false

    init() {
        // Startup config is validated by `AbbeyEngine.init`, which records the problem on
        // `engine.startupConfigError` for `ContentView` to surface. It is deliberately NOT
        // validated (and trapped on) here: `operatingMode` and the Discord token are only
        // editable from Settings inside this app, so trapping in `App.init` made a missing
        // token unfixable — the app could not launch to reach the screen that fixes it.
        let boot = Self.makeModelContainer()
        _engine = State(initialValue: AbbeyEngine(modelContainer: boot.container, storeDegraded: boot.degraded))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .onAppear {
                    // Terminal / `swift run` launches often open behind the IDE; bring forward once.
                    guard !didActivate else { return }
                    didActivate = true
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    Task { @MainActor in
                        await engine.shutdown()
                    }
                }
        }
        .modelContainer(engine.modelContainer)
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowIdealSize(.fitToContent)
        .defaultWindowPlacement { _, context in
            let display = context.defaultDisplay
            let size = CGSize(
                width: min(1100, display.visibleRect.width * 0.72),
                height: min(760, display.visibleRect.height * 0.78)
            )
            return WindowPlacement(.center, size: size)
        }
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
        let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            let result = try ModelContainerBootstrap<ModelContainer>.make(
                persistent: {
                    try ModelContainer(for: schema, configurations: [configuration])
                },
                inMemory: {
                    try ModelContainer(for: schema, configurations: [fallback])
                }
            )
            if let persistentError = result.persistentErrorDescription {
                NSLog(
                    "AbbeyBot: persistent store open failed (%@); original store left untouched; using in-memory degraded mode",
                    persistentError
                )
            }
            return (result.container, result.degraded)
        } catch {
            fatalError("AbbeyBot: could not construct any ModelContainer: \(error)")
        }
    }
}
