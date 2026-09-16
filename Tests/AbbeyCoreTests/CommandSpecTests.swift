import Testing
@testable import AbbeyCore

/// `CommandSpec` exists to stop five parallel string lists from drifting apart.
/// These tests pin the properties that made the drift dangerous rather than
/// merely untidy: an unlisted command must not become world-runnable, and a
/// command that echoes stored personal data must not reply in public.
@Suite("Command spec")
struct CommandSpecTests {
    @Test func registrationPayloadsAreDerivedFromSpecsNotMaintainedSeparately() {
        let specNames = CommandSpec.all.map(\.name)
        let registeredNames = CommandRegistry.all.map(\.name)
        #expect(registeredNames == specNames)
        #expect(CommandRegistry.all.count == CommandSpec.all.count)
    }

    @Test func everyCommandNameIsUnique() {
        let names = CommandSpec.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// The privacy invariant. Anything that reads or writes a user's stored
    /// data, or reports operator-only state, must reply only to its invoker.
    @Test func userScopedAndGlobalStateCommandsAlwaysReplyPrivately() {
        for spec in CommandSpec.all where spec.isUserScoped || spec.scope != .everyone {
            #expect(
                spec.isEphemeral,
                "\(spec.name) touches user or guild state and must not reply in channel"
            )
        }
    }

    /// The fail-safe direction. An unregistered name is the shape a typo or a
    /// half-added command takes; it must not be treated as public and harmless.
    @Test func unknownCommandsFailSafeToPrivateAndOperatorOnly() {
        #expect(CommandSpec.named("not-a-command") == nil)
        #expect(InteractionRouter.shouldRespondEphemerally(for: "not-a-command"))
        #expect(InteractionRouter.shouldRespondEphemerally(for: ""))
    }

    @Test func memoryCommandsAreTheUserScopedOnes() {
        let userScoped = Set(CommandSpec.all.filter(\.isUserScoped).map(\.name))
        #expect(userScoped == ["rep", "facts", "remember", "forget"])
    }

    @Test func guildMutatingCommandsRequireAdministratorAtRegistrationToo() {
        for spec in CommandSpec.all where spec.scope == .globalState {
            #expect(
                spec.defaultMemberPermissions?.contains(.administrator) == true,
                "\(spec.name) mutates guild state; registration must gate it too"
            )
            #expect(spec.dmPermission == false, "\(spec.name) must not be runnable in DMs")
        }
    }

    /// `/model` is the one command whose scope depends on its arguments:
    /// bare it reports, with `mode` it writes. Flattening that to "always
    /// mutating" would have locked everyone out of reading the backend.
    @Test func modelOnlyMutatesWhenAModeIsSupplied() throws {
        let model = try #require(CommandSpec.named("model"))
        #expect(!model.mutatesGlobalState { _ in false })
        #expect(model.mutatesGlobalState { $0 == "mode" })
    }

    @Test func unconditionallyMutatingCommandsIgnoreOptions() throws {
        for name in ["persona", "voice", "quasar"] {
            let spec = try #require(CommandSpec.named(name))
            #expect(spec.mutatesGlobalState { _ in false })
        }
    }

    @Test func readOnlyCommandsNeverMutateGuildState() throws {
        for name in ["ask", "explain", "ping", "help", "industry", "equity", "mod"] {
            let spec = try #require(CommandSpec.named(name))
            #expect(!spec.mutatesGlobalState { _ in true })
        }
    }
}

/// `/help` is the sixth list that once duplicated command identity. These bind
/// it to `CommandSpec.all` so the duplication cannot come back by hand.
@Suite("Help text is derived from the registry")
struct HelpTextRegistryTests {
    @Test func helpAdvertisesEveryRegisteredCommand() {
        let help = DiscordSlashLogic.helpText()
        for spec in CommandSpec.all {
            #expect(help.contains("`/\(spec.name)`"), "/help omits /\(spec.name)")
        }
    }

    @Test func helpAdvertisesNothingTheRouterWouldReject() {
        let registered = Set(CommandSpec.all.map(\.name))
        for line in DiscordSlashLogic.helpText().split(separator: "\n") {
            guard line.hasPrefix("`/") else { continue }
            let name = String(line.dropFirst(2).prefix { $0 != "`" })
            #expect(registered.contains(name), "/help advertises unregistered /\(name)")
        }
    }

    @Test func helpUsesTheDescriptionDiscordRegisters() {
        let help = DiscordSlashLogic.helpText()
        for spec in CommandSpec.all {
            #expect(help.contains(spec.description), "/help drifted from /\(spec.name)'s description")
        }
    }

    @Test func helpMarksOperatorOnlyAndPrivateCommands() {
        // `/persona` and `/model` require administrator and reply privately;
        // the hand-written literal said neither, so operators and members read
        // the same list and only found out by being refused.
        let persona = CommandSpec.named("persona")
        #expect(persona?.helpLine.contains("operator only") == true)
        #expect(persona?.helpLine.contains("private reply") == true)
        // `/ask` is open and public, so it must carry no marker at all.
        #expect(CommandSpec.named("ask")?.helpLine.contains("·") == false)
    }

    @Test func helpFitsInsideTheRouterReplyClip() {
        // InteractionRouter truncates replies past 1900 characters. A silently
        // clipped `/help` would drop the last commands registered.
        #expect(DiscordSlashLogic.helpText().count <= 1900)
    }
}
