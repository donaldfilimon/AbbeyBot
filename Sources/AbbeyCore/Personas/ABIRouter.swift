import Crypto
import Foundation

public struct PersonaRoutingReceipt: Codable, Equatable, Sendable {
    public var selectedRegister: String
    public var intent: String
    public var evidenceScopes: [String]
    public var policyFacts: [String]
    public var provenance: KnowledgeProvenance
    public var policyDigest: String
    public var timestamp: Date
}

private struct SignedPersonaRoutingPolicy: Sendable {
    var digest: String
    var verified: Bool

    static func load() -> Self {
        guard let documents = try? KnowledgeSnapshotLoader.loadVerified() else {
            return .init(digest: "unverified", verified: false)
        }
        let required = ["abi-constitution", "abi-identity", "abi-personas"]
        let selected = documents.filter { required.contains($0.id) }.sorted { $0.id < $1.id }
        guard selected.map(\.id) == required.sorted() else {
            return .init(digest: "unverified", verified: false)
        }
        let material = Data(selected.map(\.contentDigest).joined(separator: ":").utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return .init(digest: digest, verified: true)
    }
}

/// Intent → persona dispatch for Abbey / Aviva / Abi (framework roles):
/// Abbey = ethical/professional default; Aviva = analysis/research; Abi = moderation.
/// Instance-based (not a process-wide `static var`) so each engine can own its own router.
public actor ABIRouter {
    private var current: any Persona
    private let eventBus: EventBus
    private let signedPolicy: SignedPersonaRoutingPolicy
    private var receipts: [PersonaRoutingReceipt] = []

    public init(eventBus: EventBus, initial: any Persona = AbbeyPersona()) {
        self.eventBus = eventBus
        self.current = initial
        self.signedPolicy = .load()
    }

    public func currentPersona() -> any Persona {
        current
    }

    /// Routes by intent when the caller hasn't pinned a persona explicitly; falls back
    /// to whatever persona is currently active for anything not covered below.
    public func route(intent: IntentClassifier.Intent) -> any Persona {
        let selected: any Persona
        switch intent {
        case .modRequest, .command:
            selected = AbiPersona()
        case .question:
            selected = AvivaPersona()
        case .greeting, .smallTalk:
            selected = AbbeyPersona()
        default:
            selected = current
        }
        record(selected: selected.name, intent: intent, explicit: false)
        return selected
    }

    /// Resolve an explicit persona request for one reply without mutating the router's
    /// shared active persona. Global changes stay behind the authorized `/persona` command.
    public func route(intent: IntentClassifier.Intent, userText: String) -> any Persona {
        guard intent == .personaSwitch else { return route(intent: intent) }
        let selected = Self.persona(named: PersonaName.resolve(userText))
        record(selected: selected.name, intent: intent, explicit: true)
        return selected
    }

    public func setPersona(named name: String) async {
        let resolved = Self.persona(named: name)
        current = resolved
        await eventBus.publish(.personaSwitched(to: resolved.name))
    }

    public func recentRoutingReceipts() -> [PersonaRoutingReceipt] { receipts }

    private func record(selected: String, intent: IntentClassifier.Intent, explicit: Bool) {
        let scopes = intent == .modRequest || intent == .command
            ? ["authorization", "persona", "public"]
            : ["persona", "public"]
        receipts.append(.init(
            selectedRegister: selected,
            intent: intent.rawValue,
            evidenceScopes: scopes,
            policyFacts: [
                signedPolicy.verified ? "signed_abi_policy_verified" : "signed_abi_policy_unavailable",
                explicit ? "explicit_persona_request" : "intent_routing",
            ],
            provenance: signedPolicy.verified ? .measured : .reported,
            policyDigest: signedPolicy.digest,
            timestamp: Date()
        ))
        if receipts.count > 128 { receipts.removeFirst(receipts.count - 128) }
    }

    private nonisolated static func persona(named name: String) -> any Persona {
        switch name.lowercased() {
        case "aviva": return AvivaPersona()
        case "abi": return AbiPersona()
        default: return AbbeyPersona()
        }
    }
}
