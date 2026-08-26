import DiscordBM

extension AbbeyGatewayHandler {
    func onGuildCreate(_ payload: Gateway.GuildCreate) async {
        await bridge.handleGuildCreate(payload, generation: generation)
    }

    func onGuildDelete(_ payload: UnavailableGuild) async {
        await bridge.handleGuildDelete(payload, generation: generation)
    }

    func onVoiceStateUpdate(_ payload: VoiceState) async {
        await bridge.handleVoiceStateUpdate(payload, generation: generation)
    }

    func onVoiceServerUpdate(_ payload: Gateway.VoiceServerUpdate) async {
        await bridge.handleVoiceServerUpdate(payload, generation: generation)
    }
}
import Logging

struct AbbeyGatewayHandler: GatewayEventHandler {
    let event: Gateway.Event
    let hooks: DiscordEventHooks
    let bridge: DiscordBridge
    let generation: DiscordGatewayLifecycle.Generation
    let logger = Logger(label: "AbbeyBot.Gateway")

    func onReady(_ payload: Gateway.Ready) async throws {
        let userId = payload.user.id.rawValue
        await bridge.noteReady(userId: userId)
        await hooks.onReady(userId)
    }

    func onMessageCreate(_ payload: Gateway.MessageCreate) async throws {
        await hooks.onMessageCreate(payload)
    }

    func onInteractionCreate(_ payload: Interaction) async throws {
        await hooks.onInteractionCreate(payload)
    }
}
