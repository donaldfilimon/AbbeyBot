import AbbeyServerKit
import Foundation

/// Renders `/sync` output. Pure string formatting so it is unit-testable without a database.
///
/// The CLI does not push or pull — it only reads the row the desktop app reported. On the
/// default local SQLite database that row never exists, so the renderer says so explicitly
/// instead of printing a misleading "never synced".
enum CLISyncStatusReport {
    static func render(_ snapshot: SyncStatusSnapshotDTO, sharesServerDatabase: Bool) -> String {
        var lines = ["Sync status (read-only — the CLI does not push or pull):"]
        lines.append("  database: \(snapshot.databaseDialect)")

        guard sharesServerDatabase else {
            lines.append("  scope: local CLI database — desktop sync reports live in the server's DB.")
            lines.append("  hint: ABBEY_CLI_USE_SERVER_DATABASE=1 bash Scripts/run-abbey.sh")
            return lines.joined(separator: "\n")
        }

        if snapshot.reportedAt == nil {
            lines.append("  scope: shared server database — no desktop sync reported yet.")
            return lines.joined(separator: "\n")
        }

        lines.append("  scope: shared server database (desktop-reported)")
        lines.append("  last pull: \(outcome(at: snapshot.lastPullAt, error: snapshot.lastPullError))")
        lines.append("  last push: \(outcome(at: snapshot.lastPushAt, error: snapshot.lastPushError))")
        lines.append("  pending pushes: \(snapshot.pendingPushCount)")
        if let reportedAt = snapshot.reportedAt {
            lines.append("  reported at: \(format(reportedAt))")
        }
        return lines.joined(separator: "\n")
    }

    /// `ABBEY_CLI_USE_SERVER_DATABASE=1` is what `Scripts/run-abbey.sh` uses to decide whether
    /// to keep `DATABASE_URL` from `.env`, so it is the honest signal for "shared with server".
    static func sharesServerDatabase(environment: [String: String]) -> Bool {
        environment["ABBEY_CLI_USE_SERVER_DATABASE"] == "1"
    }

    private static func outcome(at date: Date?, error: String?) -> String {
        if let error, !error.isEmpty {
            let when = date.map { " at \(format($0))" } ?? ""
            return "failed\(when) — \(error)"
        }
        guard let date else { return "never" }
        return "ok at \(format(date))"
    }

    private static func format(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
