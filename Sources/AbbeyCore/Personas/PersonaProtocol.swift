import Foundation

public struct PersonaContext: Sendable {
    public var channelSummary: String
    public var userFacts: [String]
    public var reputation: Double
    public init(channelSummary: String, userFacts: [String], reputation: Double) {
        self.channelSummary = channelSummary
        self.userFacts = userFacts
        self.reputation = reputation
    }
    public static let empty = PersonaContext(channelSummary: "", userFacts: [], reputation: 0.5)
}

public struct PersonaResponse: Sendable {
    public var text: String
    public var personaName: String
    public init(text: String, personaName: String) {
        self.text = text
        self.personaName = personaName
    }
}

public protocol Persona: Sendable {
    var name: String { get }
    var systemPrompt: String { get }
    func respond(to input: String, context: PersonaContext, inference: InferenceRouter) async -> PersonaResponse
}

public extension Persona {
    func respond(to input: String, context: PersonaContext, inference: InferenceRouter) async -> PersonaResponse {
        let industry = AppConfig.shared.industryProfile.promptSuffix
        let system = industry.isEmpty ? systemPrompt : systemPrompt + "\n" + industry
        let request = InferenceRequest(
            systemPrompt: system,
            userText: input,
            contextLines: [context.channelSummary] + context.userFacts
        )
        let result = await inference.generate(request)
        return PersonaResponse(text: result.text, personaName: name)
    }
}
