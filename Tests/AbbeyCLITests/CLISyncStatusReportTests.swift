import AbbeyServerKit
import Foundation
import Testing

@testable import AbbeyCLI

@Suite("CLISyncStatusReport")
struct CLISyncStatusReportTests {
    private let reportedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func localDatabaseExplainsWhyThereIsNoDesktopReport() {
        let snapshot = SyncStatusSnapshotDTO(databaseDialect: "sqlite-file")

        let output = CLISyncStatusReport.render(snapshot, sharesServerDatabase: false)

        #expect(output.contains("local CLI database"))
        #expect(output.contains("ABBEY_CLI_USE_SERVER_DATABASE=1"))
        #expect(!output.contains("last pull:"))
    }

    @Test func sharedDatabaseWithoutAReportSaysNoneYet() {
        let snapshot = SyncStatusSnapshotDTO(databaseDialect: "postgres")

        let output = CLISyncStatusReport.render(snapshot, sharesServerDatabase: true)

        #expect(output.contains("no desktop sync reported yet"))
    }

    @Test func sharedDatabaseRendersSuccessfulPullAndPush() {
        let snapshot = SyncStatusSnapshotDTO(
            databaseDialect: "postgres",
            lastPullAt: reportedAt,
            lastPushAt: reportedAt,
            pendingPushCount: 0,
            reportedAt: reportedAt
        )

        let output = CLISyncStatusReport.render(snapshot, sharesServerDatabase: true)

        #expect(output.contains("last pull: ok at"))
        #expect(output.contains("last push: ok at"))
        #expect(output.contains("pending pushes: 0"))
    }

    /// A recorded error must win over the timestamp so a stale success can't read as healthy.
    @Test func errorsAreSurfacedInsteadOfOk() {
        let snapshot = SyncStatusSnapshotDTO(
            databaseDialect: "postgres",
            lastPullAt: reportedAt,
            lastPullError: "connection refused",
            pendingPushCount: 3,
            reportedAt: reportedAt
        )

        let output = CLISyncStatusReport.render(snapshot, sharesServerDatabase: true)

        #expect(output.contains("last pull: failed"))
        #expect(output.contains("connection refused"))
        #expect(output.contains("pending pushes: 3"))
    }

    @Test func neverPushedRendersNever() {
        let snapshot = SyncStatusSnapshotDTO(databaseDialect: "postgres", lastPullAt: reportedAt, reportedAt: reportedAt)

        let output = CLISyncStatusReport.render(snapshot, sharesServerDatabase: true)

        #expect(output.contains("last push: never"))
    }

    @Test func sharedDatabaseDetectionRequiresTheOptInFlag() {
        #expect(CLISyncStatusReport.sharesServerDatabase(environment: ["ABBEY_CLI_USE_SERVER_DATABASE": "1"]))
        #expect(!CLISyncStatusReport.sharesServerDatabase(environment: ["ABBEY_CLI_USE_SERVER_DATABASE": "0"]))
        #expect(!CLISyncStatusReport.sharesServerDatabase(environment: [:]))
    }
}
