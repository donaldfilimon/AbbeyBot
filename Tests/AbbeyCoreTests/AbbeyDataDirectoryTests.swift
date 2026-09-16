import Foundation
import Testing
@testable import AbbeyCore

/// Tests must never touch the operator's real `~/.abbey` (DQN journal, WDBX segments,
/// rollback snapshots). These pin the resolver and every default that routes through it.
@Suite struct AbbeyDataDirectoryTests {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    @Test func productionDefaultIsHomeDotAbbey() {
        let url = AbbeyDataDirectory.url(environment: [:], isTestHost: false, home: home)
        #expect(url.path == "/Users/example/.abbey")
    }

    @Test func overrideWinsEverywhere() {
        let env = [AbbeyDataDirectory.environmentKey: "/private/tmp/abbey-override"]
        #expect(AbbeyDataDirectory.url(environment: env, isTestHost: false, home: home).path == "/private/tmp/abbey-override")
        #expect(AbbeyDataDirectory.url(environment: env, isTestHost: true, home: home).path == "/private/tmp/abbey-override")
    }

    @Test func blankOverrideIsIgnored() {
        let env = [AbbeyDataDirectory.environmentKey: "  "]
        #expect(AbbeyDataDirectory.url(environment: env, isTestHost: false, home: home).path == "/Users/example/.abbey")
    }

    @Test func tildeInOverrideExpands() {
        let env = [AbbeyDataDirectory.environmentKey: "~/abbey-alt"]
        let url = AbbeyDataDirectory.url(environment: env, isTestHost: false, home: home)
        #expect(!url.path.contains("~"))
        #expect(url.path.hasSuffix("/abbey-alt"))
    }

    @Test func testHostWithoutOverrideUsesTemporaryDirectory() {
        let url = AbbeyDataDirectory.url(environment: [:], isTestHost: true, home: home)
        #expect(url == AbbeyDataDirectory.testHostFallback)
        #expect(!url.path.hasPrefix(home.path))
    }

    @Test func thisProcessIsRecognisedAsATestHost() {
        #expect(AbbeyDataDirectory.isTestHost)
    }

    /// The regression this suite exists for: every default under test resolves outside the
    /// real home data directory, whether or not a smoke script set `ABBEY_DATA_DIR`.
    @Test func everyDefaultStaysOutOfTheRealAbbeyDirectory() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".abbey", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let defaults: [URL] = [
            AbbeyDataDirectory.url(),
            try ExperienceJournalStore.defaultURL(),
            try DQNCheckpointStore.defaultURL(),
            try WDBXStore.defaultRoot(),
            try RollbackStore.abbeyHome(),
            try RollbackStore.rollbackRoot(),
        ]
        for url in defaults {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            #expect(path != real && !path.hasPrefix(real + "/"), "\(path) is inside the real ~/.abbey")
        }
    }
}
