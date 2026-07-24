import Foundation
import SwiftData
import AbbeyCore

/// Idea-generation scaffolding over a made-up universe of `QX-####` instruments.
/// This module exists to exercise factor-screening UI/UX, not to produce anything
/// resembling investment advice — per /areas/abbey-bot.md: "Financial idea-generation
/// and equity research must carry synthetic/not-advice framing at every surface
/// (Discord render, CLI render, SwiftUI disclaimer)." `EquityIdea.disclaimer` is the
/// single source of that text; every view that renders an `EquityIdea` must show it.
public struct EquityResearchEngine {
    private var rng: SplitMix64

    public init(seed: UInt64 = .random(in: .min ... .max)) {
        self.rng = SplitMix64(seed: seed)
    }

    public mutating func generateIdea() -> EquityIdea {
        let symbolNumber = Int.random(in: 1000...9999, using: &rng)
        let factors = FactorScreen.Factors(
            momentum: Double.random(in: -1...1, using: &rng),
            volatilityDampening: Double.random(in: 0...1, using: &rng),
            syntheticGrowth: Double.random(in: -1...1, using: &rng),
            noveltyPenalty: Double.random(in: 0...1, using: &rng)
        )
        let score = FactorScreen.score(factors)
        let breakdown = FactorScreen.breakdown(factors)

        let thesis = Self.thesisSentence(for: factors, score: score)

        return EquityIdea(
            symbol: "QX-\(symbolNumber)",
            thesisSummary: thesis,
            syntheticScore: score,
            factorBreakdown: breakdown
        )
    }

    public mutating func generateBatch(count: Int, context: ModelContext) -> [EquityIdea] {
        (0..<count).map { _ in
            let idea = generateIdea()
            context.insert(idea)
            return idea
        }
    }

    private static func thesisSentence(for factors: FactorScreen.Factors, score: Double) -> String {
        let momentumWord = factors.momentum > 0.2 ? "positive" : (factors.momentum < -0.2 ? "negative" : "flat")
        let growthWord = factors.syntheticGrowth > 0.2 ? "accelerating" : (factors.syntheticGrowth < -0.2 ? "decelerating" : "steady")
        return "Synthetic screen: \(momentumWord) momentum, \(growthWord) synthetic growth, composite score \(String(format: "%.2f", score)). \(EquityIdea.disclaimer)"
    }
}

// `SplitMix64` conforms to `RandomNumberGenerator` and is defined in NeuralNetwork.swift;
// `Double.random(in:using:)` and `Int.random(in:using:)` both accept it directly.
