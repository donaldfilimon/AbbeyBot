import Foundation
import DiscordBM

/// Slash /voice subcommand actions (gateway presence only — no audio).
public enum VoiceAction: Sendable, Equatable {
    case join(channelId: String)
    case leave
}

/// Slash / component / autocomplete routing for AbbeyBot.
public struct InteractionRouter: Sendable {
    private let handlers: DiscordSlashHandlers
    private let accessPolicy: DiscordCommandAccessPolicy

    public init(
        handlers: DiscordSlashHandlers,
        accessPolicy: DiscordCommandAccessPolicy = .fromEnvironment()
    ) {
        self.handlers = handlers
        self.accessPolicy = accessPolicy
    }

    /// Convenience init matching the pre-2.x surface (forwards to full handlers with stubs).
    public init(
        ask: @escaping DiscordSlashHandlers.AskHandler,
        rep: @escaping DiscordSlashHandlers.RepHandler,
        remember: @escaping DiscordSlashHandlers.RememberHandler,
        forget: @escaping DiscordSlashHandlers.ForgetHandler,
        context: @escaping DiscordSlashHandlers.ContextHandler,
        persona: @escaping DiscordSlashHandlers.PersonaHandler,
        voice: @escaping DiscordSlashHandlers.VoiceHandler,
        help: @escaping DiscordSlashHandlers.HelpHandler = { DiscordSlashLogic.helpText() },
        status: @escaping DiscordSlashHandlers.StatusHandler = { _, _ in DiscordCopy.engineUnavailable },
        model: @escaping DiscordSlashHandlers.ModelHandler = { _ in DiscordCopy.engineUnavailable },
        summarize: @escaping DiscordSlashHandlers.SummarizeHandler = { _, _, _ in DiscordCopy.engineUnavailable },
        explain: @escaping DiscordSlashHandlers.ExplainHandler = { _, _, _, _ in DiscordCopy.engineUnavailable },
        facts: @escaping DiscordSlashHandlers.FactsHandler = { _, _ in DiscordCopy.engineUnavailable },
        ping: @escaping DiscordSlashHandlers.PingHandler = {
            DiscordCopy.ping(latencyMs: 0)
        },
        equity: @escaping DiscordSlashHandlers.EquityHandler = { _ in DiscordCopy.equityDisabled },
        modAdvice: @escaping DiscordSlashHandlers.ModAdviceHandler = { _, _, _, _ in DiscordCopy.engineUnavailable },
        industry: @escaping DiscordSlashHandlers.IndustryHandler = {
            DiscordCopy.industryProfile(AppConfig.shared.industryProfile.rawValue, suffixEmpty: true)
        },
        accessPolicy: DiscordCommandAccessPolicy = .fromEnvironment()
    ) {
        self.handlers = DiscordSlashHandlers(
            ask: ask,
            rep: rep,
            remember: remember,
            forget: forget,
            context: context,
            persona: persona,
            voice: voice,
            help: help,
            status: status,
            model: model,
            summarize: summarize,
            explain: explain,
            facts: facts,
            ping: ping,
            equity: equity,
            modAdvice: modAdvice,
            industry: industry
        )
        self.accessPolicy = accessPolicy
    }

    /// 1-based forget index. Returns `nil` when missing, unparseable (caller maps to 0), or ≤ 0.
    public static func validatedForgetIndex(_ raw: Int) -> Int? {
        raw > 0 ? raw : nil
    }

    /// Commands that register autocomplete for their primary string option.
    public static func shouldProvideAutocomplete(for commandName: String) -> Bool {
        commandName == "ask" || commandName == "explain"
    }

    /// Memory, channel-context, configuration, and status responses should not be published
    /// into the channel timeline.  Ephemerality is selected on the initial defer because
    /// Discord does not allow changing that flag on the later edit.
    public static func shouldRespondEphemerally(for commandName: String) -> Bool {
        switch commandName {
        case "facts", "remember", "forget", "rep", "context", "summarize",
             "persona", "model", "status", "voice":
            return true
        default:
            return false
        }
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
        let userId = interaction.member?.user?.id.rawValue
            ?? interaction.user?.id.rawValue
            ?? ""
        let guildId = interaction.guild_id?.rawValue ?? "DM"
        let channelId = interaction.channel?.id.rawValue
            ?? interaction.channel_id?.rawValue
            ?? ""

        try? await client.createInteractionResponse(
            id: interaction.id,
            token: interaction.token,
            payload: .deferredChannelMessageWithSource(
                isEphemeral: Self.shouldRespondEphemerally(for: data.name)
            )
        ).guardSuccess()

        let targetUserId = (try? data.option(named: "user")?.requireString()) ?? userId
        let requestedModel = try? data.option(named: "mode")?.requireString()
        let permissions = interaction.member?.permissions
        let isAdministrator = permissions?.contains(.administrator) == true
        let isModerator = isAdministrator
            || permissions?.contains(.manageGuild) == true
            || permissions?.contains(.moderateMembers) == true
        let mutatesGlobalState = data.name == "persona"
            || data.name == "voice"
            || (data.name == "model" && requestedModel != nil)
        let authorized = accessPolicy.allows(.init(
            commandName: data.name,
            invokerUserId: userId,
            targetUserId: targetUserId,
            mutatesGlobalState: mutatesGlobalState,
            hasAdministratorPermission: isAdministrator,
            hasModerationPermission: isModerator
        ))

        var result: String
        if !authorized {
            result = DiscordCopy.notAuthorized
        } else { switch data.name {
        case "ask":
            let question = (try? data.option(named: "question")?.requireString()) ?? ""
            result = await handlers.ask(question, userId, guildId, channelId)
        case "explain":
            let topic = (try? data.option(named: "topic")?.requireString()) ?? ""
            result = await handlers.explain(topic, userId, guildId, channelId)
        case "summarize":
            result = await handlers.summarize(channelId, guildId, userId)
        case "rep":
            result = await handlers.rep(targetUserId, guildId)
        case "facts":
            result = await handlers.facts(targetUserId, guildId)
        case "remember":
            let fact = (try? data.option(named: "fact")?.requireString()) ?? ""
            result = await handlers.remember(targetUserId, guildId, fact)
        case "forget":
            let rawIndex = Int((try? data.option(named: "index")?.requireInt()) ?? 0)
            guard let index = Self.validatedForgetIndex(rawIndex) else {
                result = DiscordCopy.invalidFactIndex
                break
            }
            result = await handlers.forget(targetUserId, guildId, index)
        case "context":
            result = await handlers.context(channelId, guildId)
        case "persona":
            let name = (try? data.option(named: "name")?.requireString()) ?? "abbey"
            result = await handlers.persona(name)
        case "model":
            let mode = try? data.option(named: "mode")?.requireString()
            result = await handlers.model(mode)
        case "status":
            result = await handlers.status(guildId, channelId)
        case "industry":
            result = await handlers.industry()
        case "equity":
            let symbol = (try? data.option(named: "symbol")?.requireString()) ?? ""
            result = await handlers.equity(symbol)
        case "mod":
            let situation = (try? data.option(named: "situation")?.requireString()) ?? ""
            result = await handlers.modAdvice(situation, userId, guildId, channelId)
        case "ping":
            result = await handlers.ping()
        case "help":
            result = await handlers.help()
        case "voice":
            result = await handleVoice(data: data, guildId: guildId)
        default:
            result = "Unknown command. Try `/help`."
        } }

        // Discord hard limit 2000 chars
        let clipped = result.count > 1900 ? String(result.prefix(1890)) + "…" : result

        try? await client.updateOriginalInteractionResponse(
            token: interaction.token,
            payload: .init(content: clipped)
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
            return await handlers.voice(.join(channelId: channel), guildId)
        case "leave":
            return await handlers.voice(.leave, guildId)
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
        let optionName = data.name == "explain" ? "topic" : "question"
        let partial = data.options?
            .first(where: { $0.name == optionName && $0.focused == true })
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
