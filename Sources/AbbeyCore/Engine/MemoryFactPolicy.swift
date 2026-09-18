import Foundation

/// Bounds the per-user remembered-facts list. Decided 2026-09-16: at most 50 facts of at
/// most 280 characters each, oldest evicted first. Both persistence adapters
/// (`AbbeyBotApp/AbbeyEngine` and `AbbeyServerKit/MemoryRepository`) apply this on every
/// append so desktop and server never disagree about what a stored list may hold. Sync
/// copies a row's facts verbatim; a row that predates the cap is trimmed on its next append.
public enum MemoryFactPolicy: Sendable {
    public static let maxFacts = 50
    public static let maxFactLength = 280

    public struct Outcome: Equatable, Sendable {
        /// The list after the append, ready to store.
        public let facts: [String]
        /// The fact as stored (trimmed, possibly truncated); empty when nothing was stored.
        public let fact: String
        /// The list changed and must be saved. False for an empty or duplicate fact.
        public let changed: Bool
        /// The fact was cut to `maxFactLength` characters.
        public let truncated: Bool
        /// Oldest facts dropped to stay within `maxFacts`.
        public let evicted: Int
    }

    public static func appending(_ raw: String, to existing: [String]) -> Outcome {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Outcome(facts: existing, fact: "", changed: false, truncated: false, evicted: 0)
        }
        let truncated = trimmed.count > maxFactLength
        let fact = truncated ? String(trimmed.prefix(maxFactLength)) : trimmed
        guard !existing.contains(fact) else {
            return Outcome(facts: existing, fact: fact, changed: false, truncated: truncated, evicted: 0)
        }
        var facts = existing
        facts.append(fact)
        let overflow = max(0, facts.count - maxFacts)
        if overflow > 0 {
            facts.removeFirst(overflow)
        }
        return Outcome(facts: facts, fact: fact, changed: true, truncated: truncated, evicted: overflow)
    }
}
