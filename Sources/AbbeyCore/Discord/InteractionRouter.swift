import Foundation
import DiscordBM

/// Slash /voice subcommand actions (gateway presence only — no audio).
public enum VoiceAction: Sendable, Equatable {
    case join(channelId: String)
    case leave
}

/// Slash / component / autocomplete routing for AbbeyBot.
public struct InteractionRouter: Sendable {
    public typealias AskHandler = @Sendable (_ question: String, _ userId: String, _ guildId: String, _ channelId: String) async -> String
    public typealias RepHandler = @Sendable (_ userId: String, _ guildId: String) async -> String
    public typealias RememberHandler = @Sendable (_ userId: String, _ guildId: String, _ fact: String) async -> String
    public typealias ForgetHandler = @Sendable (_ userId: String, _ guildId: String, _ index: Int) async -> String
    public typealias ContextHandler = @Sendable (_ channelId: String, _ guildId: String) async -> String
    public typealias PersonaHandler = @Sendable (_ name: String) async -> String
    public typealias VoiceHandler = @Sendable (_ action: VoiceAction, _ guildId: String) async -> String

    private let ask: AskHandler
    private let rep: RepHandler
    private let remember: RememberHandler
    private let forget: ForgetHandler
    private let context: ContextHandler
    private let persona: PersonaHandler
    private let voice: VoiceHandler

    public init(
        ask: @escaping AskHandler,
        rep: @escaping RepHandler,
        remember: @escaping RememberHandler,
        forget: @escaping ForgetHandler,
        context: @escaping ContextHandler,
        persona: @escaping PersonaHandler,
        voice: @escaping VoiceHandler
    ) {
        self.ask = ask
        self.rep = rep
        self.remember = remember
        self.forget = forget
        self.context = context
        self.persona = persona
        self.voice = voice
    }

    /// 1-based forget index. Returns `nil` when missing, unparseable (caller maps to 0), or ≤ 0.
    public static func validatedForgetIndex(_ raw: Int) -> Int? {
        raw > 0 ? raw : nil
    }

    /// Only `/ask` registers autocomplete; other commands get empty choices.
    public static func shouldProvideAutocomplete(for commandName: String) -> Bool {
        commandName == "ask"
    }

    public func handle(_ interaction: Interaction, client: any DiscordClient) async {
        guard let data = interaction.data else { return }

        if interaction.type == .applicationCommandAutocomplete,
           case .applicationCommand(let command) = data {
            await handleAutocomplete(interaction, data: command, client: client)
            return
        }

        if case .applicationCommand(let command) = data {
            await handleCommand(interaction, data: command, client: client)
        }
    }

    private func handleCommand(
        _ interaction: Interaction,
        data: Interaction.ApplicationCommand,
        client: any DiscordClient
    ) async {
        try? await client.createInteractionResponse(
            id: interaction.id,
            token: interaction.token,
            payload: .deferredChannelMessageWithSource()
        ).guardSuccess()

        let userId = interaction.member?.user?.id.rawValue
            ?? interaction.user?.id.rawValue
            ?? ""
        let guildId = interaction.guild_id?.rawValue ?? "DM"
        let channelId = interaction.channel?.id.rawValue
            ?? interaction.channel_id?.rawValue
            ?? ""

        let result: String
        switch data.name {
        case "ask":
            let question = (try? data.option(named: "question")?.requireString()) ?? ""
            result = await ask(question, userId, guildId, channelId)
        case "rep":
            let target = (try? data.option(named: "user")?.requireString()) ?? userId
            result = await rep(target, guildId)
        case "remember":
            let target = (try? data.option(named: "user")?.requireString()) ?? userId
            let fact = (try? data.option(named: "fact")?.requireString()) ?? ""
            result = await remember(target, guildId, fact)
        case "forget":
            let target = (try? data.option(named: "user")?.requireString()) ?? userId
            let rawIndex = Int((try? data.option(named: "index")?.requireInt()) ?? 0)
            guard let index = Self.validatedForgetIndex(rawIndex) else {
                result = DiscordCopy.invalidFactIndex
                break
            }
            result = await forget(target, guildId, index)
        case "context":
            result = await context(channelId, guildId)
        case "persona":
            let name = (try? data.option(named: "name")?.requireString()) ?? "abbey"
            result = await persona(name)
        case "voice":
            result = await handleVoice(data: data, guildId: guildId)
        default:
            result = "Unknown command."
        }

        try? await client.updateOriginalInteractionResponse(
            token: interaction.token,
            payload: .init(content: result)
        ).guardSuccess()
    }

    private func handleVoice(
        data: Interaction.ApplicationCommand,
        guildId: String
    ) async -> String {
        guard let sub = data.options?.first else {
            return DiscordCopy.voiceUnknownSubcommand
        }
        switch sub.name {
        case "join":
            let channel = (try? sub.option(named: "channel")?.requireString()) ?? ""
            return await voice(.join(channelId: channel), guildId)
        case "leave":
            return await voice(.leave, guildId)
        default:
            return DiscordCopy.voiceUnknownSubcommand
        }
    }

    private func handleAutocomplete(
        _ interaction: Interaction,
        data: Interaction.ApplicationCommand,
        client: any DiscordClient
    ) async {
        guard Self.shouldProvideAutocomplete(for: data.name) else {
            try? await client.createInteractionResponse(
                id: interaction.id,
                token: interaction.token,
                payload: .autocompleteResult(.init(choices: []))
            ).guardSuccess()
            return
        }
        let partial = data.options?
            .first(where: { $0.name == "question" && $0.focused == true })
            .flatMap { try? $0.requireString() } ?? ""
        let suggestions = IntentClassifier.suggestCompletions(for: partial)
        let choices = suggestions.prefix(25).map {
            ApplicationCommand.Option.Choice(name: $0, value: .string($0))
        }
        try? await client.createInteractionResponse(
            id: interaction.id,
            token: interaction.token,
            payload: .autocompleteResult(.init(choices: Array(choices)))
        ).guardSuccess()
    }
}
