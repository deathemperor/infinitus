import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vite-plus/test";

const testState = vi.hoisted(() => ({
  snapshot: null as InfinitusSnapshot | null,
  stats: null as { result?: unknown } | null,
  capability: true as boolean | undefined,
  refresh: vi.fn(),
}));

vi.mock("../../env", () => ({ isElectron: false }));
vi.mock("@effect/atom-react", () => ({
  useAtomValue: () => ({ environment: { capabilities: { infinitus: testState.capability } } }),
}));
vi.mock("../../state/environments", () => ({ usePrimaryEnvironmentId: () => "test-environment" }));
vi.mock("../../state/infinitus", () => ({
  infinitusEnvironment: {
    snapshot: () => ({ label: "snapshot-atom" }),
    stats: () => ({ label: "stats-atom" }),
  },
}));
vi.mock("../../state/query", () => ({
  useEnvironmentQuery: (atom: { label: string } | null) => {
    const data =
      atom?.label === "stats-atom" ? testState.stats : atom === null ? null : testState.snapshot;
    return {
      data,
      error: null,
      isPending: data === null,
      isSuccess: data !== null,
      refresh: testState.refresh,
    };
  },
}));
vi.mock("../../state/server", () => ({ primaryServerConfigAtom: { label: "config-atom" } }));
vi.mock("../../hooks/useLocalStorage", () => ({
  useLocalStorage: (_key: string, initial: unknown) => [initial, vi.fn()],
}));
vi.mock("~/components/ui/refresh-icon", () => ({ RefreshIcon: () => null }));
vi.mock("../ui/button", () => ({ Button: "button" }));
vi.mock("../ui/scroll-area", () => ({ ScrollArea: "div" }));
vi.mock("../ui/sidebar", () => ({ SidebarInset: "div" }));
vi.mock("../ui/skeleton", () => ({ Skeleton: "div" }));
vi.mock("../WorkspaceBreadcrumb", () => ({
  WorkspaceBreadcrumb: "div",
  WorkspaceBreadcrumbItem: "div",
}));
vi.mock("../WorkspacePageContainer", () => ({ WorkspacePageContainer: "main" }));
vi.mock("../WorkspacePageHeader", () => ({ WorkspacePageHeader: "header" }));
vi.mock("../accounts/AccountsUnavailable", () => ({
  AccountsUnavailable: ({ reason }: { reason: string | null; children?: ReactNode }) => (
    <p>offline: {reason}</p>
  ),
}));

import { StatsPage } from "./StatsPage";

const readySnapshot: InfinitusSnapshot = {
  available: true,
  fleets: [],
  sessions: [],
  commands: [
    { name: "stats", args: [], options: ["period"], effect: "read", summary: "", replyShape: "" },
  ],
};

const statsReply = {
  result: {
    period: "week",
    from: "2026-09-04",
    to: "2026-09-10",
    total: {
      commits: 12,
      humanMessages: 30,
      usd: 123.456,
      sessionBuckets: [1, 2, 1, 0],
      sessionTally: 4,
      sessionSeconds: 7200,
      activities: { code: { n: 5, s: 600, in: 10, out: 20, usd: 3 } },
    },
    previous: { commits: 10 },
    daily: [{ key: "2026-09-04", day: { commits: 12 } }],
    streak: 3,
  },
};

beforeEach(() => {
  testState.snapshot = null;
  testState.stats = null;
  testState.capability = true;
  testState.refresh = vi.fn();
});

describe("StatsPage", () => {
  it("draws the tiles, session lengths and effort tables from the stats reply", () => {
    testState.snapshot = readySnapshot;
    testState.stats = statsReply;

    const markup = renderToStaticMarkup(<StatsPage />);

    expect(markup).toContain("2026-09-04 – 2026-09-10 · 3-day streak");
    expect(markup).toContain("never billing truth");
    expect(markup).toContain("Commits");
    expect(markup).toContain(">12<");
    expect(markup).toContain("+20%");
    expect(markup).toContain("Cost (API-equivalent estimate)");
    expect(markup).toContain("$123");
    expect(markup).toContain("15–60 min");
    expect(markup).toContain("Coding");
    expect(markup).toContain("Models: nothing yet this period");
  });

  it("says so when the build has no stats verb, and when there is no adapter", () => {
    testState.snapshot = { ...readySnapshot, commands: [] };
    expect(renderToStaticMarkup(<StatsPage />)).toContain(
      "This Infinitus build has no stats verb.",
    );

    testState.capability = undefined;
    expect(renderToStaticMarkup(<StatsPage />)).toContain("no Infinitus adapter");
  });

  it("shows the offline state from the snapshot", () => {
    testState.snapshot = {
      available: false,
      unavailableReason: "socket gone",
      fleets: [],
      sessions: [],
      commands: [],
    };
    expect(renderToStaticMarkup(<StatsPage />)).toContain("offline: socket gone");
  });
});
