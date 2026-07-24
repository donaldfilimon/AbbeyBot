// Typed client for the AbbeyServer JSON API. Same-origin only — the SPA is
// served by AbbeyServer itself, so no base URL / CORS configuration needed.

export interface HealthResponse {
  status: string;
  discord: "disconnected" | "connecting" | "connected" | "failed" | string;
}

export interface MetricsResponse {
  messagesIngested: number;
  reputationEvents: number;
  consolidations: string;
  inferenceCalls: number;
  inferenceFailures: number;
  liveIngestCount: number;
  discordState: string;
  discordBotUserId: string;
  lastInferenceError: string;
}

export interface StatusResponse {
  databaseDialect: string;
  discordState: string;
  botUserId: string;
  users: number;
  channels: number;
  messages: number;
  reputationEvents: number;
  equityIdeas: number;
  messagesIngested: number;
  liveIngestCount: number;
  inferenceCalls: number;
  inferenceFailures: number;
}

export interface UserRow {
  discordUserId: string;
  guildId: string;
  facts: string[];
  reputation: number;
  interactionCount: number;
  updatedAt: string | null;
}

export interface ChannelRow {
  channelId: string;
  guildId: string;
  summary: string;
  messageCount: number;
  updatedAt: string | null;
}

export interface MessageRow {
  discordMessageId: string;
  channelId: string;
  guildId: string;
  authorId: string;
  content: string;
  createdAt: string | null;
}

export interface ReputationRow {
  userId: string;
  guildId: string;
  delta: number;
  reason: string;
  createdAt: string | null;
}

export interface EquityRow {
  symbol: string;
  thesisSummary: string;
  syntheticScore: number;
  factorBreakdown: Record<string, number>;
  generatedAt: string | null;
}

export interface InteractionRow {
  commandName: string;
  userId: string;
  guildId: string;
  succeeded: boolean;
  latencyMs: number;
  createdAt: string | null;
}

async function getJSON<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: { Accept: "application/json" } });
  if (!res.ok) {
    throw new Error(`${path} -> HTTP ${res.status}`);
  }
  return (await res.json()) as T;
}

export function fetchHealth(): Promise<HealthResponse> {
  return getJSON<HealthResponse>("/health");
}

export function fetchMetrics(): Promise<MetricsResponse> {
  return getJSON<MetricsResponse>("/api/metrics");
}

export function fetchStatus(): Promise<StatusResponse> {
  return getJSON<StatusResponse>("/api/status");
}

export function fetchUsers(limit: number): Promise<UserRow[]> {
  return getJSON<UserRow[]>(`/api/users?limit=${limit}`);
}

export function fetchChannels(limit: number): Promise<ChannelRow[]> {
  return getJSON<ChannelRow[]>(`/api/channels?limit=${limit}`);
}

export function fetchMessages(limit: number): Promise<MessageRow[]> {
  return getJSON<MessageRow[]>(`/api/messages?limit=${limit}`);
}

export function fetchReputation(limit: number): Promise<ReputationRow[]> {
  return getJSON<ReputationRow[]>(`/api/reputation?limit=${limit}`);
}

export function fetchEquity(limit: number): Promise<EquityRow[]> {
  return getJSON<EquityRow[]>(`/api/equity?limit=${limit}`);
}

export function fetchInteractions(limit: number): Promise<InteractionRow[]> {
  return getJSON<InteractionRow[]>(`/api/interactions?limit=${limit}`);
}
