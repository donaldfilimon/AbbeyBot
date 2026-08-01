import type { StatusResponse } from "../api";

// Labels mirror Sources/AbbeyServer/Resources/Views/status.leaf exactly so the
// dashboard reads the same as the server-rendered status page.
const TILES: Array<{ label: string; key: keyof StatusResponse }> = [
  { label: "Database", key: "databaseDialect" },
  { label: "Discord", key: "discordState" },
  { label: "Bot user", key: "botUserId" },
  { label: "Users", key: "users" },
  { label: "Channels", key: "channels" },
  { label: "Messages", key: "messages" },
  { label: "Reputation events", key: "reputationEvents" },
  { label: "Equity ideas", key: "equityIdeas" },
  { label: "Ingested (session)", key: "messagesIngested" },
  { label: "Live Discord ingest", key: "liveIngestCount" },
  { label: "Inference calls", key: "inferenceCalls" },
  { label: "Inference failures", key: "inferenceFailures" },
  { label: "Twitch stream", key: "twitchStreamLive" },
];

function formatTileValue(
  key: keyof StatusResponse,
  value: StatusResponse[keyof StatusResponse],
): string {
  if (key === "twitchStreamLive") {
    if (value === null || value === undefined) return "unknown";
    return value ? "live" : "offline";
  }
  return String(value);
}

export interface StatTilesProps {
  status: StatusResponse | null;
  error: string | null;
}

export function StatTiles({ status, error }: StatTilesProps) {
  if (error) {
    return <p className="error-text">Failed to load /api/status: {error}</p>;
  }

  return (
    <dl className="stat-grid" data-testid="stat-grid">
      {TILES.map((tile) => (
        <div className="stat-tile" key={tile.key}>
          <dt>{tile.label}</dt>
          <dd>{status ? formatTileValue(tile.key, status[tile.key]) : "…"}</dd>
        </div>
      ))}
    </dl>
  );
}
