import Foundation

/// Local strategy + vector memory facade.
///
/// **Claim-honest:** backs onto `ExperienceJournal` (DQN JSONL) and optional
/// `WDBXStore` (segmented vector JSONL under `~/.abbey/wdbx/`). This is **not**
/// the Zig abi WDBX engine and makes no throughput or blockchain claims.
public struct WDBXMemoryFacade: Sendable {
    private let journal: ExperienceJournal
    private let store: WDBXStore?

    public init(journalURL: URL, store: WDBXStore? = nil) {
        self.journal = ExperienceJournal(url: journalURL)
        self.store = store
    }

    public init(journal: ExperienceJournal, store: WDBXStore? = nil) {
        self.journal = journal
        self.store = store
    }

    public static func `default`(store suppliedStore: WDBXStore? = nil) throws -> WDBXMemoryFacade {
        let store = suppliedStore ?? (try? WDBXStore())
        return WDBXMemoryFacade(journalURL: try ExperienceJournalStore.defaultURL(), store: store)
    }

    /// Persist one DQN transition to the journal. The transition does not carry a
    /// guild, so it is deliberately not inserted as an unscoped searchable vector.
    public func remember(_ experience: Experience) throws {
        try journal.append(experience)
    }

    public func recent(limit: Int = 100) throws -> [Experience] {
        try journal.loadRecent(limit: limit)
    }

    public func searchSimilar(
        state: [Float],
        guildId: String,
        channelId: String? = nil,
        userId: String? = nil,
        minimumSimilarity: Float = WDBXStore.safeMinimumSimilarity,
        limit: Int = 5
    ) -> [WDBXSearchHit] {
        guard let store else { return [] }
        return store.search(
            query: padOrTrim(state, to: store.dimension),
            guildId: guildId,
            channelId: channelId,
            userId: userId,
            minimumSimilarity: minimumSimilarity,
            limit: limit
        )
    }

    public func storeStats() -> (records: Int, backend: String) {
        if let store {
            return (store.recordCount, "local-wdbx-segments+\(NeuralMath.accelerationBackend)")
        }
        return (0, "experience-journal-only")
    }

    private func padOrTrim(_ v: [Float], to dim: Int) -> [Float] {
        if v.count == dim { return v }
        if v.count > dim { return Array(v.prefix(dim)) }
        return v + [Float](repeating: 0, count: dim - v.count)
    }
}
