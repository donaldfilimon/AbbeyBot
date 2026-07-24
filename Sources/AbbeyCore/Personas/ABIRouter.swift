import Foundation

/// Intent → persona dispatch. Mirrors the Vapor implementation's `ABIRouter`
/// (bot-architecture.md) but is an instance here rather than a type with `static var`
/// state, so it can be constructed per-`AbbeyEngine` instead of being a hidden global —
/// the reference draft's `static var current` made persona state a process-wide global,
/// which is fine for a single-process bot but wrong for an app that could (in principle)
/// host multiple engine instances in the same process (e.g. previews, tests).
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
            return AvivaPersona()
        case .greeting, .smallTalk:
            return AbiPersona()
        default:
            return current
        }
    }

    public func setPersona(named name: String) async {
        let resolved: any Persona
        switch name.lowercased() {
        case "aviva": resolved = AvivaPersona()
        case "abi": resolved = AbiPersona()
        default: resolved = AbbeyPersona()
        }
        current = resolved
        await eventBus.publish(.personaSwitched(to: resolved.name))
    }
}
