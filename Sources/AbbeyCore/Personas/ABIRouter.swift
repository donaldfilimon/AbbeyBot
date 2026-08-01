import Foundation

/// Intent → persona dispatch for Abbey / Aviva / Abi (framework roles):
/// Abbey = ethical/professional default; Aviva = analysis/research; Abi = moderation.
/// Instance-based (not a process-wide `static var`) so each engine can own its own router.
public actor ABIRouter {
    private var current: any Persona
    private let eventBus: EventBus

    public init(eventBus: EventBus, initial: any Persona = AbbeyPersona()) {
        self.eventBus = eventBus
        self.current = initial
    }

    public func currentPersona() -> any Persona {
        current
    }

    /// Routes by intent when the caller hasn't pinned a persona explicitly; falls back
    /// to whatever persona is currently active for anything not covered below.
    public func route(intent: IntentClassifier.Intent) -> any Persona {
        switch intent {
        case .modRequest, .command:
            return AbiPersona()
        case .question:
            return AvivaPersona()
        case .greeting, .smallTalk:
            return AbbeyPersona()
        default:
            return current
        }
    }

    /// Resolve an explicit persona request for one reply without mutating the router's
    /// shared active persona. Global changes stay behind the authorized `/persona` command.
    public func route(intent: IntentClassifier.Intent, userText: String) -> any Persona {
        guard intent == .personaSwitch else { return route(intent: intent) }
        return Self.persona(named: PersonaName.resolve(userText))
    }

    public func setPersona(named name: String) async {
        let resolved = Self.persona(named: name)
        current = resolved
        await eventBus.publish(.personaSwitched(to: resolved.name))
    }

    private nonisolated static func persona(named name: String) -> any Persona {
        switch name.lowercased() {
        case "aviva": return AvivaPersona()
        case "abi": return AbiPersona()
        default: return AbbeyPersona()
        }
    }
}
