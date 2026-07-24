import { afterEach, describe, expect, it, vi } from "vitest";
import {
  fetchChannels,
  fetchHealth,
  fetchInteractions,
  fetchStatus,
  fetchUsers,
} from "./api";

function mockFetchOnce(body: unknown, ok = true, status = 200) {
  const response = {
    ok,
    status,
    json: () => Promise.resolve(body),
  } as Response;
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue(response));
}

describe("api client", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("fetchHealth requests /health and returns the parsed shape", async () => {
    mockFetchOnce({ status: "ok", discord: "connected" });

    const result = await fetchHealth();

    expect(fetch).toHaveBeenCalledWith(
      "/health",
      expect.objectContaining({ headers: expect.any(Object) }),
    );
    expect(result).toEqual({ status: "ok", discord: "connected" });
  });

  it("fetchStatus returns all twelve status fields untouched", async () => {
    const status = {
      databaseDialect: "postgres",
      discordState: "connected",
      botUserId: "123",
      users: 4,
      channels: 2,
      messages: 100,
      reputationEvents: 3,
      equityIdeas: 1,
      messagesIngested: 50,
      liveIngestCount: 5,
      inferenceCalls: 10,
      inferenceFailures: 0,
    };
    mockFetchOnce(status);

    const result = await fetchStatus();

    expect(result).toEqual(status);
  });

  it("fetchUsers appends the limit query parameter", async () => {
    mockFetchOnce([]);

    await fetchUsers(250);

    expect(fetch).toHaveBeenCalledWith("/api/users?limit=250", expect.anything());
  });

  it("fetchChannels returns the list of rows as-is", async () => {
    const rows = [
      {
        channelId: "c1",
        guildId: "g1",
        summary: "chat about zig",
        messageCount: 42,
        updatedAt: "2026-07-01T00:00:00Z",
      },
    ];
    mockFetchOnce(rows);

    const result = await fetchChannels(100);

    expect(result).toEqual(rows);
  });

  it("fetchInteractions appends the limit and returns interaction rows", async () => {
    const rows = [
      {
        commandName: "remember",
        userId: "u1",
        guildId: "g1",
        succeeded: true,
        latencyMs: 12.4,
        createdAt: "2026-07-24T12:00:00Z",
      },
    ];
    mockFetchOnce(rows);

    const result = await fetchInteractions(100);

    expect(fetch).toHaveBeenCalledWith(
      "/api/interactions?limit=100",
      expect.objectContaining({ headers: expect.any(Object) }),
    );
    expect(result).toEqual(rows);
  });

  it("throws with the path and status when the response is not ok", async () => {
    mockFetchOnce({}, false, 500);

    await expect(fetchUsers(100)).rejects.toThrow("/api/users?limit=100");
    await expect(fetchUsers(100)).rejects.toThrow("500");
  });
});
