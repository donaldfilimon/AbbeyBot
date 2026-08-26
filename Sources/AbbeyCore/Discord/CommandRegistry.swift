import DiscordBM

public enum CommandRegistry {
    public static var all: [Payloads.ApplicationCommandCreate] {
        [
            .init(name: "ask", description: "Ask Abbey (Foundation Models / remote / floor)", options: [questionOption]),
            .init(name: "explain", description: "Explain a topic in depth", options: [topicOption]),
            .init(name: "summarize", description: "Summarize this channel’s memory with the active backend"),
            .init(name: "rep", description: "Check a user's reputation", options: [userOptionOptional]),
            .init(name: "facts", description: "List remembered facts for a user", options: [userOptionOptional]),
            .init(name: "remember", description: "Store a fact (default: for yourself)", options: [userOptionOptional, factOption]),
            .init(name: "forget", description: "Remove a stored fact (default: yours)", options: [userOptionOptional, factIndexOption]),
            .init(name: "context", description: "Show channel memory summary"),
            .init(
                name: "persona", description: "Switch active persona", options: [personaOption],
                default_member_permissions: [.administrator], dm_permission: false
            ),
            .init(
                name: "model", description: "Show or set inference backend", options: [modelModeOption],
                default_member_permissions: [.administrator], dm_permission: false
            ),
            .init(name: "status", description: "Bot + backend connection status"),
            .init(name: "industry", description: "Show industry prompt profile"),
            .init(name: "equity", description: "Synthetic equity factor screen (not advice)", options: [symbolOption]),
            .init(name: "mod", description: "Moderation advice only (no actions)", options: [situationOption]),
            .init(name: "ping", description: "Latency check"),
            .init(name: "help", description: "List AbbeyBot slash commands"),
            .init(name: "knowledge", description: "Search AbbeyBot's signed ecosystem corpus", options: [knowledgeQueryOption]),
            .init(
                name: "quasar",
                description: "Inspect sites or create a desktop-approved Quasar proposal",
                options: quasarSubcommands,
                default_member_permissions: [.administrator],
                dm_permission: false
            ),
            .init(
                name: "voice",
                description: "Join or leave voice (presence only — no audio)",
                options: [voiceJoinSubcommand, voiceLeaveSubcommand],
                default_member_permissions: [.administrator],
                dm_permission: false
            ),
        ]
    }

    public static let questionOption = ApplicationCommand.Option(
        type: .string, name: "question", description: "Your question", required: true, autocomplete: true
    )
    public static let topicOption = ApplicationCommand.Option(
        type: .string, name: "topic", description: "Topic to explain", required: true, autocomplete: true
    )
    public static let situationOption = ApplicationCommand.Option(
        type: .string, name: "situation", description: "What happened / what you’re considering", required: true
    )
    public static let symbolOption = ApplicationCommand.Option(
        type: .string, name: "symbol", description: "Ticker-like symbol (synthetic only)", required: true
    )
    public static let userOption = ApplicationCommand.Option(
        type: .user, name: "user", description: "Target user", required: true
    )
    public static let userOptionOptional = ApplicationCommand.Option(
        type: .user, name: "user", description: "Target user (default: you)", required: false
    )
    public static let factOption = ApplicationCommand.Option(
        type: .string, name: "fact", description: "Fact to remember", required: true
    )
    public static let factIndexOption = ApplicationCommand.Option(
        type: .integer, name: "index", description: "1-based fact index", required: true
    )
    public static let personaOption = ApplicationCommand.Option(
        type: .string, name: "name", description: "abbey | aviva | abi", required: true,
        choices: [
            .init(name: "Abbey", value: .string("abbey")),
            .init(name: "Aviva", value: .string("aviva")),
            .init(name: "Abi", value: .string("abi")),
        ]
    )
    public static let modelModeOption = ApplicationCommand.Option(
        type: .string,
        name: "mode",
        description: "ondevice | remote | floor (omit to show current)",
        required: false,
        choices: [
            .init(name: "onDevice (Foundation Models)", value: .string("ondevice")),
            .init(name: "remote (OpenAI-compatible)", value: .string("remote")),
            .init(name: "floor (deterministic)", value: .string("floor")),
        ]
    )
    public static let voiceChannelOption = ApplicationCommand.Option(
        type: .channel,
        name: "channel",
        description: "Voice channel to appear in",
        required: true,
        channel_types: [.guildVoice, .guildStageVoice]
    )
    public static let voiceJoinSubcommand = ApplicationCommand.Option(
        type: .subCommand,
        name: "join",
        description: "Appear in a voice channel (muted/deafened; no audio)",
        options: [voiceChannelOption]
    )
    public static let voiceLeaveSubcommand = ApplicationCommand.Option(
        type: .subCommand,
        name: "leave",
        description: "Leave voice (presence only — no audio)"
    )
    public static let knowledgeQueryOption = ApplicationCommand.Option(
        type: .string, name: "query", description: "Bounded search query", required: true
    )
    public static let quasarSiteOption = ApplicationCommand.Option(
        type: .string, name: "site", description: "Quasar site identifier", required: true
    )
    public static let quasarNameOption = ApplicationCommand.Option(
        type: .string, name: "name", description: "New site name", required: true
    )
    public static let quasarPromptOption = ApplicationCommand.Option(
        type: .string, name: "prompt", description: "Requested site change", required: true
    )
    public static let quasarSubcommands: [ApplicationCommand.Option] = [
        .init(type: .subCommand, name: "list", description: "List Quasar sites"),
        .init(type: .subCommand, name: "status", description: "Show site status", options: [quasarSiteOption]),
        .init(type: .subCommand, name: "create", description: "Propose creating a site", options: [quasarNameOption, quasarPromptOption]),
        .init(type: .subCommand, name: "edit", description: "Propose editing a site", options: [quasarSiteOption, quasarPromptOption]),
        .init(type: .subCommand, name: "archive", description: "Propose recoverable archival", options: [quasarSiteOption]),
        .init(type: .subCommand, name: "preview-start", description: "Propose starting preview", options: [quasarSiteOption]),
        .init(type: .subCommand, name: "preview-stop", description: "Propose stopping preview", options: [quasarSiteOption]),
    ]

    public static func register(client: any DiscordClient, guildId: String?) async throws {
        if let guildId, !guildId.isEmpty {
            try await client.bulkSetGuildApplicationCommands(
                guildId: GuildSnowflake(guildId),
                payload: all
            ).guardSuccess()
        } else {
            try await client.bulkSetApplicationCommands(payload: all).guardSuccess()
        }
    }
}
