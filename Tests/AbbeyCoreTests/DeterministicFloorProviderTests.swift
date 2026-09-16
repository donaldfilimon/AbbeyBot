import Testing
@testable import AbbeyCore

/// The floor provider is the path that holds when every model is unavailable,
/// and both its name and its reported `mode` claim determinism. It previously
/// chose acknowledgements with `randomElement()`, so the same message produced
/// different replies across runs — the one untested branch in the file.
@Suite("Deterministic floor provider")
struct DeterministicFloorProviderTests {
    /// Want: identical output for identical input, every time.
    /// Got, before the fix: a random pick from a four-entry bank.
    @Test func identicalInputAlwaysYieldsIdenticalOutput() async throws {
        let floor = DeterministicFloorProvider()
        let request = InferenceRequest(
            systemPrompt: "system",
            userText: "the deploy finished",
            contextLines: []
        )
        let first = try await floor.generate(request)
        for _ in 0..<24 {
            let again = try await floor.generate(request)
            #expect(again.text == first.text)
        }
    }

    /// Determinism must not collapse the bank to a single entry — the floor
    /// should still vary across different messages.
    @Test func differentInputsCanSelectDifferentBankEntries() {
        let count = 4
        let indices = Set(
            ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
                .map { DeterministicFloorProvider.stableIndex(for: $0, upperBound: count) }
        )
        #expect(indices.count > 1, "every input mapped to the same entry")
        #expect(indices.allSatisfy { $0 >= 0 && $0 < count })
    }

    @Test func stableIndexIsPureAndBounded() {
        #expect(
            DeterministicFloorProvider.stableIndex(for: "same", upperBound: 4)
                == DeterministicFloorProvider.stableIndex(for: "same", upperBound: 4)
        )
        // Must not trap on an empty bank.
        #expect(DeterministicFloorProvider.stableIndex(for: "x", upperBound: 0) == 0)
        #expect(DeterministicFloorProvider.stableIndex(for: "", upperBound: 3) < 3)
    }

    /// Documents the real limitation rather than the one the old comment
    /// claimed: the floor is keyed by intent, so persona does not change it.
    /// If persona-aware banks ever land, this test should fail and be updated.
    @Test func floorOutputIsIndependentOfPersonaSystemPrompt() async throws {
        let floor = DeterministicFloorProvider()
        let text = "the deploy finished"
        let abbey = try await floor.generate(
            .init(systemPrompt: "You are Abbey.", userText: text, contextLines: [])
        )
        let aviva = try await floor.generate(
            .init(systemPrompt: "You are Aviva.", userText: text, contextLines: [])
        )
        #expect(abbey.text == aviva.text)
    }
}
