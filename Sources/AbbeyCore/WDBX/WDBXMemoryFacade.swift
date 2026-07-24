import Foundation

/// Claim-honest local “WDBX” name for strategy memory — thin facade over
/// `ExperienceJournal` / DQN experiences. **Not** the Zig abi WDBX engine; no
/// throughput or blockchain claims.
public struct WDBXMemoryFacade: Sendable {
    private let journal: ExperienceJournal

    public init(journalURL: URL) {
        self.journal = ExperienceJournal(url: journalURL)
    }

    public init(journal: ExperienceJournal) {
        self.journal = journal
    }

    public static func `default`() throws -> WDBXMemoryFacade {
        WDBXMemoryFacade(journalURL: try ExperienceJournalStore.defaultURL())
    }

    public func remember(_ experience: Experience) throws {
        try journal.append(experience)
    }

    public func recent(limit: Int = 100) throws -> [Experience] {
        try journal.loadRecent(limit: limit)
    }
}
