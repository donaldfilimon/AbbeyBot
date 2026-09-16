import DiscordBM

/// One Discord command's complete contract: how it is registered, who may run
/// it, and whether its reply is private.
///
/// Before this type, command identity was a bare `String` replicated across
/// five independent lists — `CommandRegistry.all`, the router's ephemerality
/// switch, the router's `mutatesGlobalState` chain, the router's dispatch
/// switch, and the access policy's user-scoped switch. Nothing cross-checked
/// them, so adding a command and forgetting one list failed *silently* and in
/// the unsafe direction: a missing `mutatesGlobalState` entry leaves a
/// guild-mutating command runnable by anyone, and a missing ephemerality entry
/// publishes someone's stored facts into the channel.
///
/// Declaring the three properties together, next to the command that owns
/// them, is what makes those omissions impossible rather than merely unlikely.
public struct CommandSpec: Sendable {
    /// Where a command's reply is visible.
    public enum Visibility: Sendable, Equatable {
        /// Everyone in the channel sees the reply.
        case channel
        /// Only the invoker sees the reply. Required for anything that echoes
        /// stored personal data or operator state.
        case ephemeral
    }

    /// What a command is allowed to touch, which is what authorization keys off.
    public enum Scope: Sendable, Equatable {
        /// Reads or writes nothing beyond the invoker's own request.
        case everyone
        /// Reads or writes a *target user's* data. Permitted for yourself, or
        /// for an operator/moderator acting on someone else.
        case userScoped
        /// Changes state shared by the whole guild. Operators only.
        case globalState
        /// Changes shared state only when `option` is supplied — `/model` reads
        /// the current backend when called bare and sets it when given a mode.
        /// Modeled explicitly so the read form stays available to everyone.
        case globalStateWhenOptionPresent(String)
    }

    public let name: String
    public let description: String
    public let options: [ApplicationCommand.Option]
    public let scope: Scope
    public let visibility: Visibility
    public let defaultMemberPermissions: [Permission]?
    public let dmPermission: Bool?

    public init(
        name: String,
        description: String,
        options: [ApplicationCommand.Option] = [],
        scope: Scope = .everyone,
        visibility: Visibility = .channel,
        defaultMemberPermissions: [Permission]? = nil,
        dmPermission: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.options = options
        self.scope = scope
        self.visibility = visibility
        self.defaultMemberPermissions = defaultMemberPermissions
        self.dmPermission = dmPermission
    }

    /// Whether the reply must stay private to the invoker.
    public var isEphemeral: Bool { visibility == .ephemeral }

    /// Whether this command reads or writes another user's data, and therefore
    /// needs the self-or-moderator check rather than a blanket allow.
    public var isUserScoped: Bool { scope == .userScoped }

    /// Whether this invocation changes guild-wide state.
    ///
    /// `optionProvided` answers whether a named option was supplied, which is
    /// the only thing separating `/model` (read) from `/model mode:remote`
    /// (write).
    public func mutatesGlobalState(optionProvided: (String) -> Bool) -> Bool {
        switch scope {
        case .globalState:
            return true
        case .globalStateWhenOptionPresent(let option):
            return optionProvided(option)
        case .everyone, .userScoped:
            return false
        }
    }

    /// The Discord registration payload derived from this spec.
    public var registration: Payloads.ApplicationCommandCreate {
        .init(
            name: name,
            description: description,
            options: options.isEmpty ? nil : options,
            default_member_permissions: defaultMemberPermissions,
            dm_permission: dmPermission
        )
    }
}

extension CommandSpec {
    /// Every command AbbeyBot registers. This is the single source of truth:
    /// registration payloads, authorization scope, and reply visibility are all
    /// read from here rather than re-listed per call site.
    public static let all: [CommandSpec] = [
        .init(
            name: "ask",
            description: "Ask Abbey (Foundation Models / remote / floor)",
            options: [CommandRegistry.questionOption]
        ),
        .init(
            name: "explain",
            description: "Explain a topic in depth",
            options: [CommandRegistry.topicOption]
        ),
        .init(
            name: "summarize",
            description: "Summarize this channel’s memory with the active backend",
            visibility: .ephemeral
        ),
        .init(
            name: "rep",
            description: "Check a user's reputation",
            options: [CommandRegistry.userOptionOptional],
            scope: .userScoped,
            visibility: .ephemeral
        ),
        .init(
            name: "facts",
            description: "List remembered facts for a user",
            options: [CommandRegistry.userOptionOptional],
            scope: .userScoped,
            visibility: .ephemeral
        ),
        .init(
            name: "remember",
            description: "Store a fact (default: for yourself)",
            options: [CommandRegistry.userOptionOptional, CommandRegistry.factOption],
            scope: .userScoped,
            visibility: .ephemeral
        ),
        .init(
            name: "forget",
            description: "Remove a stored fact (default: yours)",
            options: [CommandRegistry.userOptionOptional, CommandRegistry.factIndexOption],
            scope: .userScoped,
            visibility: .ephemeral
        ),
        .init(
            name: "context",
            description: "Show channel memory summary",
            visibility: .ephemeral
        ),
        .init(
            name: "persona",
            description: "Switch active persona",
            options: [CommandRegistry.personaOption],
            scope: .globalState,
            visibility: .ephemeral,
            defaultMemberPermissions: [.administrator],
            dmPermission: false
        ),
        .init(
            name: "model",
            description: "Show or set inference backend",
            options: [CommandRegistry.modelModeOption],
            // Bare `/model` only reports; supplying `mode` is the write.
            scope: .globalStateWhenOptionPresent("mode"),
            visibility: .ephemeral,
            defaultMemberPermissions: [.administrator],
            dmPermission: false
        ),
        .init(
            name: "status",
            description: "Bot + backend connection status",
            visibility: .ephemeral
        ),
        .init(name: "industry", description: "Show industry prompt profile"),
        .init(
            name: "equity",
            description: "Synthetic equity factor screen (not advice)",
            options: [CommandRegistry.symbolOption]
        ),
        .init(
            name: "mod",
            description: "Moderation advice only (no actions)",
            options: [CommandRegistry.situationOption]
        ),
        .init(name: "ping", description: "Latency check"),
        .init(name: "help", description: "List AbbeyBot slash commands"),
        .init(
            name: "knowledge",
            description: "Search AbbeyBot's signed ecosystem corpus",
            options: [CommandRegistry.knowledgeQueryOption],
            visibility: .ephemeral
        ),
        .init(
            name: "quasar",
            description: "Inspect sites or create a desktop-approved Quasar proposal",
            options: CommandRegistry.quasarSubcommands,
            scope: .globalState,
            visibility: .ephemeral,
            defaultMemberPermissions: [.administrator],
            dmPermission: false
        ),
        .init(
            name: "voice",
            description: "Join or leave voice (presence only — no audio)",
            options: [CommandRegistry.voiceJoinSubcommand, CommandRegistry.voiceLeaveSubcommand],
            scope: .globalState,
            visibility: .ephemeral,
            defaultMemberPermissions: [.administrator],
            dmPermission: false
        ),
    ]

    /// Spec lookup by command name. `nil` means the command is not registered,
    /// which the router treats as unknown rather than guessing a policy.
    public static func named(_ name: String) -> CommandSpec? {
        all.first { $0.name == name }
    }
}
