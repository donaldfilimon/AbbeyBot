import Foundation
import Testing
@testable import AbbeyCore

@Suite("Remembered-facts bounds")
struct MemoryFactPolicyTests {
    @Test func appendsATrimmedNewFact() {
        let outcome = MemoryFactPolicy.appending("  likes tea  ", to: ["lives in nyc"])
        #expect(outcome.facts == ["lives in nyc", "likes tea"])
        #expect(outcome.fact == "likes tea")
        #expect(outcome.changed)
        #expect(!outcome.truncated)
        #expect(outcome.evicted == 0)
    }

    @Test func emptyAndDuplicateFactsChangeNothing() {
        let existing = ["likes tea"]
        let empty = MemoryFactPolicy.appending("   ", to: existing)
        #expect(!empty.changed)
        #expect(empty.facts == existing)
        #expect(empty.fact.isEmpty)

        let duplicate = MemoryFactPolicy.appending("likes tea", to: existing)
        #expect(!duplicate.changed)
        #expect(duplicate.facts == existing)
    }

    @Test func truncatesToTheLengthCapAndDedupesOnTheStoredText() {
        let long = String(repeating: "x", count: MemoryFactPolicy.maxFactLength + 40)
        let first = MemoryFactPolicy.appending(long, to: [])
        #expect(first.truncated)
        #expect(first.fact.count == MemoryFactPolicy.maxFactLength)
        #expect(first.facts == [first.fact])

        // The same long input again matches what was stored, so it is a duplicate.
        let again = MemoryFactPolicy.appending(long, to: first.facts)
        #expect(!again.changed)
        #expect(again.facts.count == 1)
    }

    @Test func evictsTheOldestBeyondTheCountCap() {
        let full = (1...MemoryFactPolicy.maxFacts).map { "fact \($0)" }
        let outcome = MemoryFactPolicy.appending("fact 51", to: full)
        #expect(outcome.evicted == 1)
        #expect(outcome.facts.count == MemoryFactPolicy.maxFacts)
        #expect(outcome.facts.first == "fact 2")
        #expect(outcome.facts.last == "fact 51")
    }

    /// A row synced from before the cap can hold more than the cap; one append trims it.
    @Test func trimsAnOversizedLegacyListOnAppend() {
        let legacy = (1...(MemoryFactPolicy.maxFacts + 10)).map { "old \($0)" }
        let outcome = MemoryFactPolicy.appending("new", to: legacy)
        #expect(outcome.evicted == 11)
        #expect(outcome.facts.count == MemoryFactPolicy.maxFacts)
        #expect(outcome.facts.last == "new")
    }
}
