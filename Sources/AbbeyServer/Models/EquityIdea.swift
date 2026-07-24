import Fluent
import Foundation
import Vapor

final class EquityIdea: Model, Content, @unchecked Sendable {
    static let schema = "equity_ideas"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "thesis_summary")
    var thesisSummary: String

    @Field(key: "synthetic_score")
    var syntheticScore: Double

    @Field(key: "factor_breakdown")
    var factorBreakdown: [String: Double]

    @Timestamp(key: "generated_at", on: .create)
    var generatedAt: Date?

    static let disclaimer =
        "Synthetic instrument, synthetic data. Not investment advice, not a real security."

    init() {}

    init(
        id: UUID? = nil,
        symbol: String,
        thesisSummary: String,
        syntheticScore: Double,
        factorBreakdown: [String: Double]
    ) {
        self.id = id
        self.symbol = symbol
        self.thesisSummary = thesisSummary
        self.syntheticScore = syntheticScore
        self.factorBreakdown = factorBreakdown
    }
}
