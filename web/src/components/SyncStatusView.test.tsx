import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { SyncStatusResponse } from "../api";
import { SyncStatusView } from "./SyncStatusView";

const healthyStatus: SyncStatusResponse = {
  id: "abc-123",
  lastPullAt: "2026-07-24T12:00:00Z",
  lastPullError: null,
  lastPushAt: "2026-07-24T12:01:00Z",
  lastPushError: null,
  pendingPushCount: 0,
  reportedAt: "2026-07-24T12:01:05Z",
};

describe("SyncStatusView", () => {
  it("renders last pull/push times and a clean pending count when healthy", () => {
    render(<SyncStatusView status={healthyStatus} error={null} />);

    expect(screen.getByText("Last pull")).toBeInTheDocument();
    expect(screen.getByText("Last push")).toBeInTheDocument();
    expect(screen.getByText("Pending pushes")).toBeInTheDocument();
    expect(screen.getByText("0")).toBeInTheDocument();
    expect(screen.queryByTestId("sync-pull-error")).not.toBeInTheDocument();
    expect(screen.queryByTestId("sync-push-error")).not.toBeInTheDocument();
  });

  it("surfaces pull and push errors and a nonzero pending count", () => {
    const status: SyncStatusResponse = {
      ...healthyStatus,
      lastPullError: "timeout",
      lastPushError: "HTTP 500",
      pendingPushCount: 3,
    };
    render(<SyncStatusView status={status} error={null} />);

    expect(screen.getByTestId("sync-pull-error")).toHaveTextContent("timeout");
    expect(screen.getByTestId("sync-push-error")).toHaveTextContent("HTTP 500");
    expect(screen.getByText("3")).toBeInTheDocument();
  });

  it("shows a never-reported placeholder when the desktop hasn't synced yet", () => {
    const status: SyncStatusResponse = {
      id: null,
      lastPullAt: null,
      lastPullError: null,
      lastPushAt: null,
      lastPushError: null,
      pendingPushCount: 0,
      reportedAt: null,
    };
    render(<SyncStatusView status={status} error={null} />);

    expect(screen.getByText(/desktop app hasn't reported/i)).toBeInTheDocument();
  });

  it("renders an error message instead of the panel when the fetch fails", () => {
    render(<SyncStatusView status={null} error="HTTP 500" />);

    expect(screen.getByText(/Failed to load \/api\/sync-status/)).toBeInTheDocument();
    expect(screen.queryByText("Last pull")).not.toBeInTheDocument();
  });
});
