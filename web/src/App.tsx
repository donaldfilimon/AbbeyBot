import { useCallback, useState } from "react";
import "./App.css";
import {
  type ChannelRow,
  type EquityRow,
  type MessageRow,
  type ReputationRow,
  type UserRow,
  fetchChannels,
  fetchEquity,
  fetchHealth,
  fetchMessages,
  fetchMetrics,
  fetchReputation,
  fetchStatus,
  fetchUsers,
} from "./api";
import { HealthStrip } from "./components/HealthStrip";
import { ListView } from "./components/ListView";
import { StatTiles } from "./components/StatTiles";
import { usePolling } from "./usePolling";

const POLL_INTERVAL_MS = 10_000;

type Tab = "overview" | "users" | "channels" | "messages" | "reputation" | "equity";

const TABS: Array<{ id: Tab; label: string }> = [
  { id: "overview", label: "Overview" },
  { id: "users", label: "Users" },
  { id: "channels", label: "Channels" },
  { id: "messages", label: "Messages" },
  { id: "reputation", label: "Reputation" },
  { id: "equity", label: "Equity" },
];

function formatDate(value: string | null): string {
  if (!value) return "—";
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? value : parsed.toLocaleString();
}

function App() {
  const [tab, setTab] = useState<Tab>("overview");

  const health = usePolling(fetchHealth, POLL_INTERVAL_MS);
  const metrics = usePolling(fetchMetrics, POLL_INTERVAL_MS);
  const status = usePolling(fetchStatus, POLL_INTERVAL_MS);

  // Stable fetcher references so ListView's effect doesn't refire every render.
  const usersFetcher = useCallback((limit: number) => fetchUsers(limit), []);
  const channelsFetcher = useCallback((limit: number) => fetchChannels(limit), []);
  const messagesFetcher = useCallback((limit: number) => fetchMessages(limit), []);
  const reputationFetcher = useCallback((limit: number) => fetchReputation(limit), []);
  const equityFetcher = useCallback((limit: number) => fetchEquity(limit), []);

  return (
    <div className="app">
      <header className="app-header">
        <h1>AbbeyServer</h1>
        <p className="muted">Read-only dashboard over the AbbeyServer JSON API.</p>
      </header>

      <HealthStrip
        health={health.data}
        healthError={health.error}
        metrics={metrics.data}
        metricsError={metrics.error}
      />

      <nav className="tabs">
        {TABS.map((t) => (
          <button
            type="button"
            key={t.id}
            className={t.id === tab ? "tab tab-active" : "tab"}
            onClick={() => setTab(t.id)}
          >
            {t.label}
          </button>
        ))}
      </nav>

      <main>
        {tab === "overview" && <StatTiles status={status.data} error={status.error} />}

        {tab === "users" && (
          <ListView<UserRow>
            title="Users"
            fetcher={usersFetcher}
            keyFor={(row, i) => `${row.discordUserId}-${row.guildId}-${i}`}
            columns={[
              { header: "Discord user", render: (r) => r.discordUserId },
              { header: "Guild", render: (r) => r.guildId },
              { header: "Reputation", render: (r) => r.reputation },
              { header: "Interactions", render: (r) => r.interactionCount },
              { header: "Facts", render: (r) => r.facts.join(", ") || "—" },
              { header: "Updated", render: (r) => formatDate(r.updatedAt) },
            ]}
          />
        )}

        {tab === "channels" && (
          <ListView<ChannelRow>
            title="Channels"
            fetcher={channelsFetcher}
            keyFor={(row, i) => `${row.channelId}-${i}`}
            columns={[
              { header: "Channel", render: (r) => r.channelId },
              { header: "Guild", render: (r) => r.guildId },
              { header: "Messages", render: (r) => r.messageCount },
              { header: "Summary", render: (r) => r.summary || "—" },
              { header: "Updated", render: (r) => formatDate(r.updatedAt) },
            ]}
          />
        )}

        {tab === "messages" && (
          <ListView<MessageRow>
            title="Messages"
            fetcher={messagesFetcher}
            keyFor={(row, i) => `${row.discordMessageId}-${i}`}
            columns={[
              { header: "Message", render: (r) => r.discordMessageId },
              { header: "Channel", render: (r) => r.channelId },
              { header: "Author", render: (r) => r.authorId },
              { header: "Content", render: (r) => r.content },
              { header: "Created", render: (r) => formatDate(r.createdAt) },
            ]}
          />
        )}

        {tab === "reputation" && (
          <ListView<ReputationRow>
            title="Reputation"
            fetcher={reputationFetcher}
            keyFor={(row, i) => `${row.userId}-${row.createdAt}-${i}`}
            columns={[
              { header: "User", render: (r) => r.userId },
              { header: "Guild", render: (r) => r.guildId },
              { header: "Delta", render: (r) => r.delta },
              { header: "Reason", render: (r) => r.reason },
              { header: "Created", render: (r) => formatDate(r.createdAt) },
            ]}
          />
        )}

        {tab === "equity" && (
          <ListView<EquityRow>
            title="Equity"
            fetcher={equityFetcher}
            keyFor={(row, i) => `${row.symbol}-${i}`}
            columns={[
              { header: "Symbol", render: (r) => r.symbol },
              { header: "Score", render: (r) => r.syntheticScore },
              { header: "Thesis", render: (r) => r.thesisSummary },
              {
                header: "Factors",
                render: (r) =>
                  Object.entries(r.factorBreakdown)
                    .map(([k, v]) => `${k}: ${v}`)
                    .join(", ") || "—",
              },
              { header: "Generated", render: (r) => formatDate(r.generatedAt) },
            ]}
          />
        )}
      </main>
    </div>
  );
}

export default App;
