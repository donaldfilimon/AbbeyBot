import type { HealthResponse, MetricsResponse } from "../api";

export interface HealthStripProps {
  health: HealthResponse | null;
  healthError: string | null;
  metrics: MetricsResponse | null;
  metricsError: string | null;
}

export function HealthStrip({
  health,
  healthError,
  metrics,
  metricsError,
}: HealthStripProps) {
  return (
    <div className="health-strip" data-testid="health-strip">
      <div className="health-item">
        <span className="health-label">Status</span>
        <span className={`badge badge-${health?.status ?? "unknown"}`}>
          {healthError ? "error" : (health?.status ?? "…")}
        </span>
      </div>
      <div className="health-item">
        <span className="health-label">Discord</span>
        <span className={`badge badge-${health?.discord ?? "unknown"}`}>
          {healthError ? "error" : (health?.discord ?? "…")}
        </span>
      </div>
      <div className="health-item">
        <span className="health-label">Inference calls</span>
        <span>{metricsError ? "—" : (metrics?.inferenceCalls ?? "…")}</span>
      </div>
      <div className="health-item">
        <span className="health-label">Inference failures</span>
        <span>{metricsError ? "—" : (metrics?.inferenceFailures ?? "…")}</span>
      </div>
      <div className="health-item">
        <span className="health-label">Live ingest</span>
        <span>{metricsError ? "—" : (metrics?.liveIngestCount ?? "…")}</span>
      </div>
      <div className="health-item">
        <span className="health-label">Last inference error</span>
        <span className="muted">
          {metricsError ? "—" : metrics?.lastInferenceError || "none"}
        </span>
      </div>
    </div>
  );
}
