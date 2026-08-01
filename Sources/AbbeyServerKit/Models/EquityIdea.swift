import Fluent
import Foundation
import Vapor

public final class EquityIdea: Model, Content, @unchecked Sendable {
    public static let schema = "equity_ideas"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "symbol")
    public var symbol: String

    @Field(key: "thesis_summary")
    public var thesisSummary: String

    @Field(key: "synthetic_score")
    public var syntheticScore: Double

    @Field(key: "factor_breakdown")
    public var factorBreakdown: [String: Double]

    @Timestamp(key: "generated_at", on: .create)
    public var generatedAt: Date?

    /// Original server generation clock for a CLI-mirrored row.
    @OptionalField(key: "source_generated_at")
    public var sourceGeneratedAt: Date?

    @OptionalField(key: "deleted_at")
    public var deletedAt: Date?

    public static let disclaimer =
        "Synthetic instrument, synthetic data. Not investment advice, not a real security."

    public init() {}

    public init(
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
