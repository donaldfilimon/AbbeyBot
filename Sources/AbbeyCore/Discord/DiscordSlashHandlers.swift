import Foundation

public struct DiscordCommandAuthorizationRequest: Sendable, Equatable {
    public var commandName: String
    public var invokerUserId: String
    public var targetUserId: String?
    public var mutatesGlobalState: Bool
    public var hasAdministratorPermission: Bool
    public var hasModerationPermission: Bool

    public init(
        commandName: String,
        invokerUserId: String,
        targetUserId: String? = nil,
        mutatesGlobalState: Bool = false,
        hasAdministratorPermission: Bool = false,
        hasModerationPermission: Bool = false
    ) {
        self.commandName = commandName
        self.invokerUserId = invokerUserId
        self.targetUserId = targetUserId
        self.mutatesGlobalState = mutatesGlobalState
        self.hasAdministratorPermission = hasAdministratorPermission
        self.hasModerationPermission = hasModerationPermission
    }
}

public enum DiscordQuasarAction: String, Sendable, Equatable {
    case list, status, create, edit, archive, previewStart, previewStop
}

public struct DiscordQuasarRequest: Sendable, Equatable {
    public var action: DiscordQuasarAction
    public var siteID: String?
    public var name: String?
    public var prompt: String?
    public var initiatorID: String
    public var guildID: String
    public var managerAuthorized: Bool

    public init(
        action: DiscordQuasarAction,
        siteID: String? = nil,
        name: String? = nil,
        prompt: String? = nil,
        initiatorID: String,
        guildID: String,
        managerAuthorized: Bool
    ) {
        self.action = action
        self.siteID = siteID
        self.name = name
        self.prompt = prompt
        self.initiatorID = initiatorID
        self.guildID = guildID
        self.managerAuthorized = managerAuthorized
    }
}

/// Runtime command policy. Registration-time Discord permissions are only defense in
/// depth; this policy remains authoritative after commands have already been registered.
public struct DiscordCommandAccessPolicy: Sendable, Equatable {
    public var operatorUserIds: Set<String>

    public init(operatorUserIds: Set<String> = []) {
        self.operatorUserIds = operatorUserIds
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let ids = (environment["DISCORD_OPERATOR_USER_IDS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Self(operatorUserIds: Set(ids))
    }

    public func allows(_ request: DiscordCommandAuthorizationRequest) -> Bool {
        guard !request.invokerUserId.isEmpty else { return false }
        let isOperator = operatorUserIds.contains(request.invokerUserId)
            || request.hasAdministratorPermission
        if request.mutatesGlobalState { return isOperator }

        // Scope is a property of the command, so it is read from the command's
        // spec rather than passed in. A caller cannot forget to mark a memory
        // command user-scoped and silently widen who may target whom.
        guard CommandSpec.named(request.commandName)?.isUserScoped == true else { return true }
        guard let target = request.targetUserId, !target.isEmpty else { return true }
        return target == request.invokerUserId || isOperator || request.hasModerationPermission
    }
}

/// Closure bag for Discord slash commands. Shared by desktop `AbbeyEngine` and server `BotRuntime`
/// so both surfaces stay feature-parity when registering handlers.
public struct DiscordSlashHandlers: Sendable {
    public typealias AskHandler = @Sendable (_ question: String, _ userId: String, _ guildId: String, _ channelId: String) async -> String
    public typealias RepHandler = @Sendable (_ userId: String, _ guildId: String) async -> String
    public typealias RememberHandler = @Sendable (_ userId: String, _ guildId: String, _ fact: String) async -> String
    public typealias ForgetHandler = @Sendable (_ userId: String, _ guildId: String, _ index: Int) async -> String
    public typealias ContextHandler = @Sendable (_ channelId: String, _ guildId: String) async -> String
    public typealias PersonaHandler = @Sendable (_ name: String) async -> String
    public typealias VoiceHandler = @Sendable (_ action: VoiceAction, _ guildId: String) async -> String
    public typealias HelpHandler = @Sendable () async -> String
    public typealias StatusHandler = @Sendable (_ guildId: String, _ channelId: String) async -> String
    public typealias ModelHandler = @Sendable (_ mode: String?) async -> String
    public typealias SummarizeHandler = @Sendable (_ channelId: String, _ guildId: String, _ userId: String) async -> String
    public typealias ExplainHandler = @Sendable (_ topic: String, _ userId: String, _ guildId: String, _ channelId: String) async -> String
    public typealias FactsHandler = @Sendable (_ userId: String, _ guildId: String) async -> String
    public typealias PingHandler = @Sendable () async -> String
    public typealias EquityHandler = @Sendable (_ symbol: String) async -> String
    public typealias ModAdviceHandler = @Sendable (_ situation: String, _ userId: String, _ guildId: String, _ channelId: String) async -> String
    public typealias IndustryHandler = @Sendable () async -> String
    public typealias KnowledgeHandler = @Sendable (_ query: String, _ userId: String, _ guildId: String) async -> String
    public typealias QuasarHandler = @Sendable (_ request: DiscordQuasarRequest) async -> String
    public typealias AuditHandler = @Sendable (
        _ commandName: String,
        _ userId: String,
        _ guildId: String,
        _ succeeded: Bool,
        _ latencyMs: Double
    ) async -> Void

    public var ask: AskHandler
    public var rep: RepHandler
    public var remember: RememberHandler
    public var forget: ForgetHandler
    public var context: ContextHandler
    public var persona: PersonaHandler
    public var voice: VoiceHandler
    public var help: HelpHandler
    public var status: StatusHandler
    public var model: ModelHandler
    public var summarize: SummarizeHandler
    public var explain: ExplainHandler
    public var facts: FactsHandler
    public var ping: PingHandler
    public var equity: EquityHandler
    public var modAdvice: ModAdviceHandler
    public var industry: IndustryHandler
    public var knowledge: KnowledgeHandler
    public var quasar: QuasarHandler
    public var audit: AuditHandler

    public init(
        ask: @escaping AskHandler,
        rep: @escaping RepHandler,
        remember: @escaping RememberHandler,
        forget: @escaping ForgetHandler,
        context: @escaping ContextHandler,
        persona: @escaping PersonaHandler,
        voice: @escaping VoiceHandler,
        help: @escaping HelpHandler,
        status: @escaping StatusHandler,
        model: @escaping ModelHandler,
        summarize: @escaping SummarizeHandler,
        explain: @escaping ExplainHandler,
        facts: @escaping FactsHandler,
        ping: @escaping PingHandler,
        equity: @escaping EquityHandler,
        modAdvice: @escaping ModAdviceHandler,
        industry: @escaping IndustryHandler,
        knowledge: @escaping KnowledgeHandler = { _, _, _ in DiscordCopy.engineUnavailable },
        quasar: @escaping QuasarHandler = { _ in DiscordCopy.engineUnavailable },
        audit: @escaping AuditHandler = { _, _, _, _, _ in }
    ) {
        self.ask = ask
        self.rep = rep
        self.remember = remember
        self.forget = forget
        self.context = context
        self.persona = persona
        self.voice = voice
        self.help = help
        self.status = status
        self.model = model
        self.summarize = summarize
        self.explain = explain
        self.facts = facts
        self.ping = ping
        self.equity = equity
        self.modAdvice = modAdvice
        self.industry = industry
        self.knowledge = knowledge
        self.quasar = quasar
        self.audit = audit
    }
}

/// Shared pure helpers for slash-command parsing / formatting (unit-testable without Discord).
public enum DiscordSlashLogic: Sendable {
    /// Map user-facing inference mode tokens to `InferenceMode`.
    public static func resolveInferenceMode(_ raw: String) -> InferenceMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ondevice", "on-device", "foundation", "fm", "apple", "local":
            return .onDevice
        case "remote", "remotecompatible", "remote-compatible", "openai", "api":
            return .remoteCompatible
        case "floor", "deterministic", "deterministicfloor", "offline", "rules":
            return .deterministicFloor
        default:
            return InferenceMode(rawValue: raw)
        }
    }

    public static func displayInferenceMode(_ mode: InferenceMode) -> String {
        switch mode {
        case .onDevice: return "onDevice (Apple Foundation Models)"
        case .remoteCompatible: return "remoteCompatible (OpenAI-compatible HTTP)"
        case .deterministicFloor: return "deterministicFloor (offline rules)"
        }
    }

    public static func helpText() -> String {
        """
        **AbbeyBot commands**
        `/ask` — question (Foundation Models / remote / floor via `/model`)
        `/explain` — deeper explanation of a topic
        `/summarize` — summarize this channel’s memory
        `/rep` — reputation score
        `/facts` — list remembered facts for a user
        `/remember` / `/forget` — store or drop a fact
        `/context` — channel memory summary
        `/persona` — abbey | aviva | abi
        `/model` — show or set inference backend
        `/status` — bot + backend connections
        `/industry` — industry prompt profile
        `/equity` — synthetic factor screen (not financial advice)
        `/mod` — moderation *advice* only (Abi; does not kick/ban)
        `/voice join|leave` — voice **presence** only (no audio)
        `/knowledge` — search the signed ecosystem corpus with citations
        `/quasar` — list/status or create a short-lived operator proposal
        `/ping` — latency check
        `/help` — this list
        """
    }

    /// Deterministic synthetic factors from a ticker symbol (not market data).
    public static func syntheticEquityFactors(for symbol: String) -> FactorScreen.Factors {
        let s = symbol.uppercased()
        var h: UInt64 = 5381
        for b in s.utf8 {
            h = ((h &<< 5) &+ h) &+ UInt64(b)
        }
        func unit(_ shift: Int) -> Double {
            let v = Double((h &>> shift) & 0xFFFF) / Double(0xFFFF)
            return v * 2 - 1
        }
        let momentum = unit(0)
        let growth = unit(16)
        let volDamp = (unit(8) + 1) / 2
        let novelty = min(max((unit(24) + 1) / 2, 0), 1)
        return FactorScreen.Factors(
            momentum: momentum,
            volatilityDampening: volDamp,
            syntheticGrowth: growth,
            noveltyPenalty: novelty
        )
    }

    public static func formatEquity(symbol: String, enabled: Bool) -> String {
        guard enabled else {
            return DiscordCopy.equityDisabled
        }
        let clean = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !clean.isEmpty, clean.count <= 12, clean.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return DiscordCopy.equityBadSymbol
        }
        let factors = syntheticEquityFactors(for: clean)
        let score = FactorScreen.score(factors)
        let parts = FactorScreen.breakdown(factors)
            .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
            .sorted()
            .joined(separator: ", ")
        return DiscordCopy.equityResult(symbol: clean, score: score, factors: parts)
    }

    public static func formatFacts(userId: String, facts: [String]) -> String {
        if facts.isEmpty { return DiscordCopy.noMemory }
        let lines = facts.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return "**Facts for \(userId)**\n" + lines.joined(separator: "\n")
    }
}
