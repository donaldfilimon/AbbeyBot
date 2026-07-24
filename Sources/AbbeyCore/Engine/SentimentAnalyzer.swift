import Foundation

/// Produces the 18-dimensional state vector fed to `DQNAgent`. Dimension count is a
/// pinned architectural constant (see /areas/abbey-bot.md: "SentimentAnalyzer (DQN state
/// dimension 18)") — the components below were chosen to add up to exactly 18 so this
/// stays true if you add or reorder features.
public struct SentimentAnalyzer {
    public static let stateDimension = 18

    /// Lightweight lexicon-based scoring — deliberately not an ML model itself,
    /// since it *feeds* the DQN rather than duplicating it. Stdlib-only, no dependency.
    private static let positiveWords: Set<String> = [
        "good", "great", "love", "nice", "thanks", "awesome", "lol", "lmao", "based", "fire", "goated"
    ]
    private static let negativeWords: Set<String> = [
        "bad", "hate", "worst", "annoying", "trash", "cringe", "mid", "toxic", "rude"
    ]

    /// Builds the full 18-dim state for a message given surrounding context.
    ///   [0]      normalized message length (0...1, capped at 280 chars)
    ///   [1]      exclamation density
    ///   [2]      question mark density
    ///   [3]      uppercase-letter ratio ("shouting")
    ///   [4]      positive-word density
    ///   [5]      negative-word density
    ///   [6]      emoji/reaction density (from `recentReactionCount`)
    ///   [7]      mentions-someone flag (0 or 1)
    ///   [8]      is-reply flag (0 or 1)
    ///   [9]      current reputation of the author (0...1)
    ///   [10]     time-of-day, encoded as sin(hour)
    ///   [11]     time-of-day, encoded as cos(hour) — paired with [10] so midnight
    ///            isn't discontinuous with 23:00
    ///   [12]     channel activity level (messages in the last consolidation window,
    ///            normalized against `activityNormalizationCeiling`)
    ///   [13]     author's interaction count, log-normalized
    ///   [14]     intent quality score (`IntentClassifier.Intent.quality`)
    ///   [15]     is-command flag (0 or 1)
    ///   [16]     is-DM flag (0 or 1)
    ///   [17]     bias term (constant 1.0)
    public static func analyze(
        text: String,
        authorReputation: Double,
        recentReactionCount: Int,
        mentionsSomeone: Bool,
        isReply: Bool,
        timestamp: Date,
        channelMessageCountInWindow: Int,
        authorInteractionCount: Int,
        isDirectMessage: Bool,
        activityNormalizationCeiling: Double = 200
    ) -> [Float] {
        let lower = text.lowercased()
        let words = lower.split(separator: " ").map(String.init)
        let wordCount = max(words.count, 1)

        let lengthNormalized = min(Double(text.count) / 280.0, 1.0)
        let exclamationDensity = min(Double(text.filter { $0 == "!" }.count) / Double(wordCount), 1.0)
        let questionDensity = min(Double(text.filter { $0 == "?" }.count) / Double(wordCount), 1.0)
        let uppercaseRatio: Double = {
            let letters = text.filter { $0.isLetter }
            guard !letters.isEmpty else { return 0 }
            let uppercase = letters.filter { $0.isUppercase }
            return Double(uppercase.count) / Double(letters.count)
        }()
        let positiveDensity = Double(words.filter { positiveWords.contains($0) }.count) / Double(wordCount)
        let negativeDensity = Double(words.filter { negativeWords.contains($0) }.count) / Double(wordCount)
        let reactionDensity = min(Double(recentReactionCount) / 20.0, 1.0)

        let intent = IntentClassifier.classify(text)
        let hourFraction = Calendar.current.component(.hour, from: timestamp)
        let angle = 2.0 * Double.pi * Double(hourFraction) / 24.0

        let state: [Double] = [
            lengthNormalized,
            exclamationDensity,
            questionDensity,
            uppercaseRatio,
            positiveDensity,
            negativeDensity,
            reactionDensity,
            mentionsSomeone ? 1 : 0,
            isReply ? 1 : 0,
            authorReputation,
            sin(angle),
            cos(angle),
            min(Double(channelMessageCountInWindow) / activityNormalizationCeiling, 1.0),
            log1p(Double(authorInteractionCount)) / log1p(1000.0),
            intent.quality,
            intent == .command ? 1 : 0,
            isDirectMessage ? 1 : 0,
            1.0
        ]

        assert(state.count == stateDimension, "SentimentAnalyzer state vector drifted from the pinned 18-dim contract")
        return state.map { Float($0) }
    }

    /// Projects the pinned 18-dim state into the 8 SIMD lanes `NeuralNetwork` actually
    /// consumes. Keeps the highest-signal social/sentiment features rather than silently
    /// truncating to `prefix(8)` (which would drop reputation, intent quality, and bias).
    public static func projectToNetworkInput(_ state: [Float]) -> [Float] {
        precondition(state.count >= stateDimension, "expected \(stateDimension)-dim state, got \(state.count)")
        return [
            state[4],  // positive density
            state[5],  // negative density
            state[9],  // author reputation
            state[7],  // mentions-someone
            state[8],  // is-reply
            state[14], // intent quality
            state[12], // channel activity
            state[17], // bias
        ]
    }
}
