import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { StatusResponse } from "../api";
import { StatTiles } from "./StatTiles";

const status: StatusResponse = {
  databaseDialect: "postgres",
  discordState: "connected",
  botUserId: "1234567890",
  users: 12,
  channels: 5,
  messages: 999,
  reputationEvents: 7,
  equityIdeas: 3,
  messagesIngested: 42,
  liveIngestCount: 6,
  inferenceCalls: 88,
  inferenceFailures: 2,
  twitchStreamLive: true,
};

describe("StatTiles", () => {
  it("renders all thirteen status fields with labels matching status.leaf", () => {
    render(<StatTiles status={status} error={null} />);

    expect(screen.getByText("Database")).toBeInTheDocument();
    expect(screen.getByText("postgres")).toBeInTheDocument();

    expect(screen.getByText("Bot user")).toBeInTheDocument();
    expect(screen.getByText("1234567890")).toBeInTheDocument();

    expect(screen.getByText("Reputation events")).toBeInTheDocument();
    expect(screen.getByText("7")).toBeInTheDocument();

    expect(screen.getByText("Equity ideas")).toBeInTheDocument();
    expect(screen.getByText("Ingested (session)")).toBeInTheDocument();
    expect(screen.getByText("Live Discord ingest")).toBeInTheDocument();
    expect(screen.getByText("Inference calls")).toBeInTheDocument();
    expect(screen.getByText("Inference failures")).toBeInTheDocument();
    expect(screen.getByText("Twitch stream")).toBeInTheDocument();
    expect(screen.getByText("live")).toBeInTheDocument();
  });

  it("formats twitchStreamLive null as unknown and false as offline", () => {
    render(<StatTiles status={{ ...status, twitchStreamLive: null }} error={null} />);
    expect(screen.getByText("unknown")).toBeInTheDocument();

    render(<StatTiles status={{ ...status, twitchStreamLive: false }} error={null} />);
    expect(screen.getByText("offline")).toBeInTheDocument();
  });

  it("shows a loading placeholder for every tile before data arrives", () => {
    render(<StatTiles status={null} error={null} />);

    const grid = screen.getByTestId("stat-grid");
    const placeholders = grid.querySelectorAll("dd");
    expect(placeholders.length).toBe(13);
    for (const dd of placeholders) {
      expect(dd.textContent).toBe("…");
    }
  });

  it("renders an error message instead of tiles when the status fetch fails", () => {
    render(<StatTiles status={null} error="HTTP 500" />);

    expect(screen.getByText(/Failed to load \/api\/status/)).toBeInTheDocument();
    expect(screen.queryByTestId("stat-grid")).not.toBeInTheDocument();
  });
});
