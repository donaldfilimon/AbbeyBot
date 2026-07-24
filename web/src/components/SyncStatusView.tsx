import type { SyncStatusResponse } from "../api";

export interface SyncStatusViewProps {
  status: SyncStatusResponse | null;
  error: string | null;
}

function formatDate(value: string | null): string {
  if (!value) return "—";
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? value : parsed.toLocaleString();
}

export function SyncStatusView({ status, error }: SyncStatusViewProps) {
  if (error) {
    return <p className="error-text">Failed to load /api/sync-status: {error}</p>;
  }

  if (!status) {
    return <p className="muted">…</p>;
  }

  const neverReported = status.reportedAt === null;

  return (
    <div data-testid="sync-status-panel">
      {neverReported && (
        <p className="muted">
          The desktop app hasn't reported a sync yet — this fills in after its first
          pull (on launch, or Settings → "Pull now").
        </p>
      )}

      <dl className="stat-grid" data-testid="sync-status-grid">
        <div className="stat-tile">
          <dt>Last pull</dt>
          <dd>{formatDate(status.lastPullAt)}</dd>
          {status.lastPullError && (
            <p className="error-text" data-testid="sync-pull-error">
              {status.lastPullError}
            </p>
          )}
        </div>

        <div className="stat-tile">
          <dt>Last push</dt>
          <dd>{formatDate(status.lastPushAt)}</dd>
          {status.lastPushError && (
            <p className="error-text" data-testid="sync-push-error">
              {status.lastPushError}
            </p>
          )}
        </div>

        <div className="stat-tile">
          <dt>Pending pushes</dt>
          <dd>{status.pendingPushCount}</dd>
        </div>
      </dl>
    </div>
  );
}
