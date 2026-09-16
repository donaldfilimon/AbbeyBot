import Foundation
import Testing
@testable import AbbeyCore

/// Captures the prompt a persona actually assembles, so the manifest is proven
/// to reach the model rather than merely to exist as a string.
private actor PromptCapturingProvider: InferenceProvider {
    nonisolated let mode = InferenceMode.remoteCompatible
    nonisolated let capabilities: Set<InferenceCapability> = [.text]
    private(set) var lastSystemPrompt = ""

    func generate(_ request: InferenceRequest) async throws -> InferenceResult {
        lastSystemPrompt = request.systemPrompt
        return .init(text: "ok", mode: mode)
    }
}

/// A model asked "what can you do" invents plausible Discord-bot features
/// unless something bounds it. These pin the bound to the registry.
@Suite("Capability manifest")
struct CapabilityManifestTests {
    @Test func manifestNamesEveryRegisteredCommand() {
        let manifest = CommandSpec.capabilityManifest
        for spec in CommandSpec.all {
            #expect(manifest.contains("/\(spec.name)"), "manifest omits /\(spec.name)")
        }
    }

    @Test func manifestDeniesTheCapabilitiesThatDoNotExist() {
        // No role call, no DM-channel creation, and `all` is a compiled constant,
        // so each of these is a denial of something genuinely absent from the tree.
        let manifest = CommandSpec.capabilityManifest
        #expect(manifest.contains("roles"))
        #expect(manifest.contains("direct message"))
        #expect(manifest.contains("slash commands"))
        #expect(manifest.contains("kick"))
    }

    @Test func personaPromptCarriesTheManifest() async {
        let provider = PromptCapturingProvider()
        let router = InferenceRouter(
            eventBus: EventBus(), metrics: EngineMetrics(), currentMode: { .remoteCompatible },
            remoteEndpoint: { "" }, providerOverrides: [.remoteCompatible: provider]
        )
        _ = await AbbeyPersona().respond(
            to: "what can you do?", context: .empty, inference: router
        )
        let prompt = await provider.lastSystemPrompt
        #expect(prompt.contains("You are Abbey"), "persona register was dropped")
        #expect(prompt.contains("Do not describe any capability outside this list"))
        #expect(prompt.contains("/knowledge"), "manifest did not reach the model")
    }

    @Test func everyPersonaCarriesTheManifest() async {
        // Routing sends questions to Aviva and mod requests to Abi, so grounding
        // only the default persona would leave both live paths unbounded.
        for persona in [AbbeyPersona() as any Persona, AvivaPersona(), AbiPersona()] {
            let provider = PromptCapturingProvider()
            let router = InferenceRouter(
                eventBus: EventBus(), metrics: EngineMetrics(), currentMode: { .remoteCompatible },
                remoteEndpoint: { "" }, providerOverrides: [.remoteCompatible: provider]
            )
            _ = await persona.respond(to: "hi", context: .empty, inference: router)
            let prompt = await provider.lastSystemPrompt
            #expect(prompt.contains("Your slash commands are exactly"), "\(persona.name) is ungrounded")
        }
    }
}
