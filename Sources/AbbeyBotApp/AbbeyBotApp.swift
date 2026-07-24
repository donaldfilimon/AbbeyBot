import SwiftUI
import SwiftData
import AppKit
import AbbeyCore

/// Root entry point for AbbeyBot desktop — SwiftUI + SwiftData + DiscordBM.
@main
struct AbbeyBotApp: App {
    @State private var engine: AbbeyEngine
    @State private var didActivate = false

    init() {
        do {
            try AppConfig.shared.validateForStartup()
        } catch {
            fatalError("AbbeyBot startup validation failed: \(error.localizedDescription)")
        }
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
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return (container, false)
        } catch {
            // Lightweight migration cannot rewrite attribute types (e.g. EquityIdea.factorBreakdown
            // Binary Data → Codable). Move the on-disk store aside (not delete — keeps it available
            // for manual recovery/inspection) and retry with a fresh store before degrading.
            NSLog("AbbeyBot: persistent store open failed (%@); backing up %@",
                  error.localizedDescription, configuration.url.path)
            Self.backUpStoreFiles(at: configuration.url)
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

    /// Renames the SQLite store and its `-wal`/`-shm` sidecars aside (timestamped `.bak-<epoch>`
    /// suffix) so SwiftData can recreate a fresh schema, without discarding the old data — it stays
    /// on disk next to the live store for manual recovery/inspection.
    private static func backUpStoreFiles(at url: URL) {
        let fm = FileManager.default
        let suffix = ".bak-\(Int(Date().timeIntervalSince1970))"
        let candidates = [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm")
        ]
        for file in candidates where fm.fileExists(atPath: file.path) {
            let backupURL = URL(fileURLWithPath: file.path + suffix)
            do {
                try fm.moveItem(at: file, to: backupURL)
            } catch {
                NSLog("AbbeyBot: failed to back up store file %@: %@", file.path, error.localizedDescription)
            }
        }
    }
}
