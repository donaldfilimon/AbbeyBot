import DiscordBM
import Logging

struct AbbeyGatewayHandler: GatewayEventHandler {
    let event: Gateway.Event
    let hooks: DiscordEventHooks
    let bridge: DiscordBridge
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
