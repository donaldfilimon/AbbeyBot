import AbbeyCore
import AbbeyQuasarKit
import Foundation
import SwiftData
import Testing
@testable import AbbeyBotApp

@MainActor struct QuasarBackendSelectionTests {
    @Test func remoteStartupDoesNotOwnALocalServiceAndSettingsWaitForRestart() async throws {
        let scratch = try ScratchDefaults("quasar-backend-test")
        defer { scratch.remove() }
        let defaults = scratch.defaults
        let config = AppConfig(defaults: defaults, environment: [
            "ABBEY_QUASAR_BACKEND": "remote", "ABBEY_QUASAR_ENDPOINT": "https://api.example.test",
            "ABBEY_QUASAR_API_TOKEN": "test-token", "ABBEY_DRY_RUN": "1",
            "ABBEY_INFERENCE_MODE": "deterministicFloor"
        ], tokens: InMemoryTokenStore())
        let schema = Schema([GuildMessage.self, UserMemory.self, ChannelContext.self,
            ReputationEvent.self, InteractionLog.self, EquityIdea.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let engine = AbbeyEngine(modelContainer: container, config: config)
        #expect(engine.quasarService == nil)
        #expect(engine.quasarInitializationError == nil)
        #expect(engine.quasarWorkspaceClient is HTTPQuasarWorkspaceClient)
        config.quasarBackend = .local
        config.quasarEndpoint = "https://replacement.example.test"
        #expect(engine.quasarService == nil)
        let captured = try #require(engine.quasarWorkspaceClient as? HTTPQuasarWorkspaceClient)
        #expect(captured.endpoint.host == "api.example.test")
        await engine.shutdown()
    }
}
