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
        knowledge: @escaping DiscordSlashHandlers.KnowledgeHandler = { _, _, _ in DiscordCopy.engineUnavailable },
        quasar: @escaping DiscordSlashHandlers.QuasarHandler = { _ in DiscordCopy.engineUnavailable },
        audit: @escaping DiscordSlashHandlers.AuditHandler = { _, _, _, _, _ in },
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
            industry: industry,
            knowledge: knowledge,
            quasar: quasar,
            audit: audit
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
    /// Whether a command's reply stays private to its invoker.
    ///
    /// Read from `CommandSpec`, so a new command declares its visibility once
    /// where it is defined instead of being remembered here. An unregistered
    /// name is treated as ephemeral: failing private is the safe direction.
    public static func shouldRespondEphemerally(for commandName: String) -> Bool {
        CommandSpec.named(commandName)?.isEphemeral ?? true
    }

    /// Audit success means an authorized command completed its handler path
    /// and both Discord response writes succeeded. Domain-level refusals are
    /// still valid command responses; transport failures and denied commands
    /// must never be recorded as successful interactions.
    public static func auditSucceeded(
        authorized: Bool,
        initialResponseSucceeded: Bool,
        finalResponseSucceeded: Bool
    ) -> Bool {
        authorized && initialResponseSucceeded && finalResponseSucceeded
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
        let started = ContinuousClock.now
        let userId = interaction.member?.user?.id.rawValue
            ?? interaction.user?.id.rawValue
            ?? ""
        let guildId = interaction.guild_id?.rawValue ?? "DM"
        let channelId = interaction.channel?.id.rawValue
            ?? interaction.channel_id?.rawValue
            ?? ""

        let initialResponseSucceeded: Bool
        do {
            try await client.createInteractionResponse(
                id: interaction.id,
                token: interaction.token,
                payload: .deferredChannelMessageWithSource(
                    isEphemeral: Self.shouldRespondEphemerally(for: data.name)
                )
            ).guardSuccess()
            initialResponseSucceeded = true
        } catch {
            initialResponseSucceeded = false
        }

        let targetUserId = data.string(named: "user") ?? userId
        let permissions = interaction.member?.permissions
        let isAdministrator = permissions?.contains(.administrator) == true
        let isModerator = isAdministrator
            || permissions?.contains(.manageGuild) == true
            || permissions?.contains(.moderateMembers) == true
        // Both facts come from the command's own spec rather than a string
        // list maintained here, so an unlisted command can no longer default
        // to "mutates nothing" and slip past the operator check.
        let spec = CommandSpec.named(data.name)
        let mutatesGlobalState = spec?.mutatesGlobalState { option in
            data.string(named: option) != nil
        } ?? true
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
            let question = data.string(named: "question") ?? ""
            result = await handlers.ask(question, userId, guildId, channelId)
        case "explain":
            let topic = data.string(named: "topic") ?? ""
            result = await handlers.explain(topic, userId, guildId, channelId)
        case "summarize":
            result = await handlers.summarize(channelId, guildId, userId)
        case "rep":
            result = await handlers.rep(targetUserId, guildId)
        case "facts":
            result = await handlers.facts(targetUserId, guildId)
        case "remember":
            let fact = data.string(named: "fact") ?? ""
            result = await handlers.remember(targetUserId, guildId, fact)
        case "forget":
            let rawIndex = Int(data.int(named: "index") ?? 0)
            guard let index = Self.validatedForgetIndex(rawIndex) else {
                result = DiscordCopy.invalidFactIndex
                break
            }
            result = await handlers.forget(targetUserId, guildId, index)
        case "context":
            result = await handlers.context(channelId, guildId)
        case "persona":
            let name = data.string(named: "name") ?? "abbey"
            result = await handlers.persona(name)
        case "model":
            let mode = data.string(named: "mode")
            result = await handlers.model(mode)
        case "status":
            result = await handlers.status(guildId, channelId)
        case "industry":
            result = await handlers.industry()
        case "equity":
            let symbol = data.string(named: "symbol") ?? ""
            result = await handlers.equity(symbol)
        case "mod":
            let situation = data.string(named: "situation") ?? ""
            result = await handlers.modAdvice(situation, userId, guildId, channelId)
        case "ping":
            result = await handlers.ping()
        case "help":
            result = await handlers.help()
        case "knowledge":
            let query = data.string(named: "query") ?? ""
            result = await handlers.knowledge(query, userId, guildId)
        case "quasar":
            result = await handleQuasar(
                data: data,
                userId: userId,
                guildId: guildId,
                managerAuthorized: isAdministrator || isModerator
            )
        case "voice":
            result = await handleVoice(data: data, guildId: guildId)
        default:
            result = "Unknown command. Try `/help`."
        } }

        // Discord hard limit 2000 chars
        let clipped = result.count > 1900 ? String(result.prefix(1890)) + "…" : result

        let finalResponseSucceeded: Bool
        do {
            try await client.updateOriginalInteractionResponse(
                token: interaction.token,
                payload: .init(content: clipped)
            ).guardSuccess()
            finalResponseSucceeded = true
        } catch {
            finalResponseSucceeded = false
        }
        await handlers.audit(
            data.name,
            userId,
            guildId,
            Self.auditSucceeded(
                authorized: authorized,
                initialResponseSucceeded: initialResponseSucceeded,
                finalResponseSucceeded: finalResponseSucceeded
            ),
            IngestScorer.latencyMilliseconds(since: started)
        )
    }

    private func handleQuasar(
        data: Interaction.ApplicationCommand,
        userId: String,
        guildId: String,
        managerAuthorized: Bool
    ) async -> String {
        guard let sub = data.options?.first else { return "Choose a Quasar subcommand." }
        let action: DiscordQuasarAction
        switch sub.name {
        case "list": action = .list
        case "status": action = .status
        case "create": action = .create
        case "edit": action = .edit
        case "archive": action = .archive
        case "preview-start": action = .previewStart
        case "preview-stop": action = .previewStop
        default: return "Unknown Quasar subcommand."
        }
        return await handlers.quasar(.init(
            action: action,
            siteID: sub.string(named: "site"),
            name: sub.string(named: "name"),
            prompt: sub.string(named: "prompt"),
            initiatorID: userId,
            guildID: guildId,
            managerAuthorized: managerAuthorized
        ))
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
            let channel = sub.string(named: "channel") ?? ""
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


/// Option reads for slash-command payloads.
///
/// Every call site used to spell this out as
/// `(try? data.option(named: "x")?.requireString()) ?? ""`, fifteen times. That is not only
/// repetition: it collapses two different outcomes — the option was **absent**, and the
/// option was **present but the wrong type** — into one empty string, so a malformed payload
/// reaches a handler looking exactly like a user who typed nothing. These accessors preserve
/// today's behaviour exactly (both cases still yield `nil`), but they put the distinction in
/// one place, so deciding to reject malformed input later is a change to this file rather
/// than to fifteen call sites.
extension Interaction.ApplicationCommand {
    /// The named option's string value, or `nil` when it is absent or not a string.
    func string(named name: String) -> String? {
        try? option(named: name)?.requireString()
    }

    /// The named option's integer value, or `nil` when it is absent or not an integer.
    func int(named name: String) -> Int? {
        try? option(named: name)?.requireInt()
    }
}

extension Interaction.ApplicationCommand.Option {
    /// The named sub-option's string value, or `nil` when it is absent or not a string.
    func string(named name: String) -> String? {
        try? option(named: name)?.requireString()
    }
}
