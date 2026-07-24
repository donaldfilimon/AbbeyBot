import type { HealthResponse, MetricsResponse } from "../api";

export interface HealthStripProps {
  health: HealthResponse | null;
  healthError: string | null;
  metrics: MetricsResponse | null;
  metricsError: string | null;
}

function pendingOr(value: string | number | undefined, errored: boolean): string {
  if (errored) return "—";
  if (value === undefined) return "—";
  return String(value);
}

export function HealthStrip({
  health,
  healthError,
  metrics,
  metricsError,
}: HealthStripProps) {
  const statusValue = healthError ? "error" : (health?.status ?? "—");
  const discordValue = healthError ? "error" : (health?.discord ?? "—");
  const statusBadge = healthError ? "error" : (health?.status ?? "unknown");
  const discordBadge = healthError ? "error" : (health?.discord ?? "unknown");

  return (
    <div className="health-strip" data-testid="health-strip">
      <div className="health-item">
        <span className="health-label">Health</span>
        <span className={`badge badge-${statusBadge}`}>{statusValue}</span>
      </div>
      <div className="health-item">
        <span className="health-label">Discord</span>
        <span className={`badge badge-${discordBadge}`}>{discordValue}</span>
      </div>
      <div className="health-item">
        <span className="health-label">Inference calls</span>
        <span className="health-value">
          {pendingOr(metrics?.inferenceCalls, Boolean(metricsError))}
        </span>
      </div>
      <div className="health-item">
        <span className="health-label">Inference failures</span>
        <span className="health-value">
          {pendingOr(metrics?.inferenceFailures, Boolean(metricsError))}
        </span>
      </div>
      <div className="health-item">
        <span className="health-label">Live Discord ingest</span>
        <span className="health-value">
          {pendingOr(metrics?.liveIngestCount, Boolean(metricsError))}
        </span>
      </div>
      <div className="health-item">
        <span className="health-label">Last inference error</span>
        <span className="muted health-value">
          {metricsError ? "—" : metrics?.lastInferenceError || "none"}
        </span>
      </div>
    </div>
  );
}
