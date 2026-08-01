import Testing
@testable import AbbeyCore

@Suite("InteractionRouter guards")
struct InteractionRouterGuardsTests {
    @Test func validatedForgetIndexAcceptsPositiveOneBased() {
        #expect(InteractionRouter.validatedForgetIndex(1) == 1)
        #expect(InteractionRouter.validatedForgetIndex(2) == 2)
        #expect(InteractionRouter.validatedForgetIndex(99) == 99)
    }

    @Test func validatedForgetIndexRejectsMissingZeroAndNegative() {
        #expect(InteractionRouter.validatedForgetIndex(0) == nil)
        #expect(InteractionRouter.validatedForgetIndex(-1) == nil)
        #expect(InteractionRouter.validatedForgetIndex(-40) == nil)
    }

    @Test func autocompleteForAskAndExplain() {
        #expect(InteractionRouter.shouldProvideAutocomplete(for: "ask"))
        #expect(InteractionRouter.shouldProvideAutocomplete(for: "explain"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "forget"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "rep"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "remember"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "context"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "persona"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "voice"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: "status"))
        #expect(!InteractionRouter.shouldProvideAutocomplete(for: ""))
    }

    @Test func sensitiveCommandsAreEphemeral() {
        for command in ["facts", "remember", "forget", "rep", "context", "summarize", "model", "status", "voice"] {
            #expect(InteractionRouter.shouldRespondEphemerally(for: command))
        }
        #expect(!InteractionRouter.shouldRespondEphemerally(for: "ask"))
        #expect(!InteractionRouter.shouldRespondEphemerally(for: "help"))
    }

    @Test func commandAccessScopesMemoryAndGlobalMutations() {
        let policy = DiscordCommandAccessPolicy(operatorUserIds: ["owner"])
        #expect(policy.allows(.init(commandName: "facts", invokerUserId: "u1", targetUserId: "u1")))
        #expect(!policy.allows(.init(commandName: "facts", invokerUserId: "u1", targetUserId: "u2")))
        #expect(policy.allows(.init(
            commandName: "facts", invokerUserId: "mod", targetUserId: "u2",
            hasModerationPermission: true
        )))
        #expect(policy.allows(.init(
            commandName: "model", invokerUserId: "owner", mutatesGlobalState: true
        )))
        #expect(!policy.allows(.init(
            commandName: "model", invokerUserId: "u1", mutatesGlobalState: true
        )))
        #expect(policy.allows(.init(
            commandName: "voice", invokerUserId: "admin", mutatesGlobalState: true,
            hasAdministratorPermission: true
        )))
    }
}

@Suite("Discord slash pure logic")
struct DiscordSlashLogicTests {
    @Test func resolveInferenceModeAliases() {
        #expect(DiscordSlashLogic.resolveInferenceMode("ondevice") == .onDevice)
        #expect(DiscordSlashLogic.resolveInferenceMode("Foundation") == .onDevice)
        #expect(DiscordSlashLogic.resolveInferenceMode("remote") == .remoteCompatible)
        #expect(DiscordSlashLogic.resolveInferenceMode("floor") == .deterministicFloor)
        #expect(DiscordSlashLogic.resolveInferenceMode("nope") == nil)
    }

    @Test func equityDisabledAndBadSymbol() {
        #expect(DiscordSlashLogic.formatEquity(symbol: "AAPL", enabled: false) == DiscordCopy.equityDisabled)
        #expect(DiscordSlashLogic.formatEquity(symbol: "!!!", enabled: true) == DiscordCopy.equityBadSymbol)
    }

    @Test func equitySyntheticDeterministic() {
        let a = DiscordSlashLogic.formatEquity(symbol: "AAPL", enabled: true)
        let b = DiscordSlashLogic.formatEquity(symbol: "aapl", enabled: true)
        #expect(a == b)
        #expect(a.contains("AAPL"))
        #expect(a.contains("Not financial advice"))
    }

    @Test func formatFactsEmptyAndListed() {
        #expect(DiscordSlashLogic.formatFacts(userId: "u1", facts: []) == DiscordCopy.noMemory)
        let listed = DiscordSlashLogic.formatFacts(userId: "u1", facts: ["likes swift", "uses zsh"])
        #expect(listed.contains("1. likes swift"))
        #expect(listed.contains("2. uses zsh"))
    }

    @Test func helpMentionsFoundationModels() {
        let help = DiscordSlashLogic.helpText()
        #expect(help.contains("/ask"))
        #expect(help.contains("/model"))
        #expect(help.contains("Foundation Models"))
    }

    @Test func commandRegistryRegistersExpandedSurface() {
        let names = Set(CommandRegistry.all.map(\.name))
        for expected in [
            "ask", "explain", "summarize", "rep", "facts", "remember", "forget",
            "context", "persona", "model", "status", "industry", "equity", "mod",
            "ping", "help", "voice",
        ] {
            #expect(names.contains(expected), "missing slash command \(expected)")
        }
        for name in ["persona", "model", "voice"] {
            let command = CommandRegistry.all.first { $0.name == name }
            #expect(command?.default_member_permissions?.contains(.administrator) == true)
            #expect(command?.dm_permission == false)
        }
    }
}
