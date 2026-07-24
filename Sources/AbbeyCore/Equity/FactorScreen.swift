import Foundation

/// Scores a synthetic instrument against a small factor set. Every number here is
/// generated, not sourced from any real market feed — see EquityIdea.disclaimer, which
/// must be shown wherever a score from this type is rendered.
public struct FactorScreen {
    public struct Factors: Sendable {
        public var momentum: Double        // -1...1
        public var volatilityDampening: Double  // 0...1, higher = calmer synthetic series
        public var syntheticGrowth: Double  // -1...1
        public var noveltyPenalty: Double   // 0...1, higher = more penalty (over-hyped pattern)
        public init(momentum: Double, volatilityDampening: Double, syntheticGrowth: Double, noveltyPenalty: Double) {
            self.momentum = momentum
            self.volatilityDampening = volatilityDampening
            self.syntheticGrowth = syntheticGrowth
            self.noveltyPenalty = noveltyPenalty
        }
    }

    public static func score(_ factors: Factors) -> Double {
        let raw = (factors.momentum * 0.35)
            + (factors.volatilityDampening * 0.25)
            + (factors.syntheticGrowth * 0.30)
            - (factors.noveltyPenalty * 0.10)
        // Clamp into 0...1 for display as a "score", not a return forecast.
        return min(max((raw + 1) / 2, 0), 1)
    }

    public static func breakdown(_ factors: Factors) -> [String: Double] {
        [
            "momentum": factors.momentum,
            "volatilityDampening": factors.volatilityDampening,
            "syntheticGrowth": factors.syntheticGrowth,
            "noveltyPenalty": factors.noveltyPenalty
        ]
    }
}
