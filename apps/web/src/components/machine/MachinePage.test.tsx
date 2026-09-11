import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vite-plus/test";

const NOW_ISO = "2026-09-11T03:05:00.000Z";

const testState = vi.hoisted(() => ({
  snapshot: null as InfinitusSnapshot | null,
  machine: null as { result?: unknown } | null,
  capability: true as boolean | undefined,
  refresh: vi.fn(),
}));

vi.mock("../../env", () => ({ isElectron: false }));
vi.mock("@effect/atom-react", () => ({
  useAtomValue: () => ({ environment: { capabilities: { infinitus: testState.capability } } }),
}));
vi.mock("../../hooks/useNowMinute", () => ({ useNowMinute: () => NOW_ISO }));
vi.mock("../../hooks/useSettings", () => ({
  usePrimarySettings: (selector: (settings: { timestampFormat: string }) => unknown) =>
    selector({ timestampFormat: "24-hour" }),
}));
vi.mock("../../state/environments", () => ({ usePrimaryEnvironmentId: () => "test-environment" }));
vi.mock("../../state/infinitus", () => ({
  infinitusEnvironment: {
    snapshot: () => ({ label: "snapshot-atom" }),
    machine: () => ({ label: "machine-atom" }),
  },
}));
vi.mock("../../state/query", () => ({
  useEnvironmentQuery: (atom: { label: string } | null) => {
    const data =
      atom?.label === "machine-atom"
        ? testState.machine
        : atom === null
          ? null
          : testState.snapshot;
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

import { MachinePage } from "./MachinePage";

const readySnapshot: InfinitusSnapshot = {
  available: true,
  fleets: [],
  sessions: [],
  commands: [
    { name: "machine", args: [], options: [], effect: "read", summary: "", replyShape: "" },
  ],
};

const hook = (owner: string, event: string, spawnsPerHour: number, instances = 0) => ({
  registration: {
    event,
    command: `python3 ${owner}.py`,
    source: { plugin: { _0: owner } },
    ownerKind: "plugin",
    owner,
  },
  spawnsPerHour,
  live: { instances, helpers: 0, oldestSeconds: instances > 0 ? 720 : 0, uninterruptible: 0 },
});

const machineReply = {
  result: {
    sample: {
      at: "2026-09-11T03:00:40Z",
      cores: 16,
      load1: 15.57,
      load5: 20.97,
      swapUsedMB: 10759,
      swapTotalMB: 12288,
      processes: 1349,
      running: 13,
      uninterruptible: 0,
      zombies: 11,
      windowServerCPU: 72.8,
      claudeRSSMB: 6443,
    },
    hooks: [
      ...Array.from({ length: 13 }, (_, index) =>
        hook(`owner-${index}`, "PreToolUse", 100 + index),
      ),
      hook("wedged", "Stop", 10, 60),
    ],
    runaways: [
      {
        pid: 4242,
        command: "pip install x",
        rule: "retry-loop",
        why: "21 spawns in an hour",
        rssMB: 80,
        elapsedSeconds: 900,
      },
    ],
    residue: {
      staleSockets: 3,
      staleSessionEnvs: 1,
      tempEntries: 43889,
      transcriptsBytes: 2_621_440,
      pluginCacheBytes: 0,
      memBytes: 0,
    },
    sessions: [
      {
        pid: 12,
        name: "limitless",
        cwd: "/Users/x/limitless",
        rssMB: 300,
        ageSeconds: 7200,
        lastActivityAt: "2026-09-10T23:30:00Z",
      },
    ],
    warnings: ["temp directory holds 43889 entries"],
  },
};

beforeEach(() => {
  testState.snapshot = null;
  testState.machine = null;
  testState.capability = true;
  testState.refresh = vi.fn();
});

describe("MachinePage", () => {
  it("draws the summary, warnings, top hook owners, runaways, residue and sessions", () => {
    testState.snapshot = readySnapshot;
    testState.machine = machineReply;

    const markup = renderToStaticMarkup(<MachinePage />);

    expect(markup).toContain("15.57 / 16 cores");
    expect(markup).toContain("10759 / 12288 MB");
    expect(markup).toContain("Listing timed out");
    expect(markup).toContain("temp directory holds 43889 entries");
    // The stuck owner sorts first; twelve owners show, the rest wait behind Show all.
    expect(markup.indexOf("wedged")).toBeLessThan(markup.indexOf("owner-12"));
    expect(markup).toContain("1 stuck");
    expect(markup).toContain("60 live");
    expect(markup).toContain("Heavy");
    expect(markup).toContain("Show all 14 owners");
    expect(markup).not.toContain("owner-0<");
    expect(markup).toContain("pip install x");
    expect(markup).toContain("Stale sockets");
    expect(markup).toContain("2.5 MB");
    expect(markup).toContain("limitless");
    expect(markup).toContain("120 min");
    expect(markup).toContain("3 h");
    expect(markup).toContain("stay in the Mac app");
  });

  it("says so while native is still sampling, and when the reply is unreadable", () => {
    testState.snapshot = readySnapshot;
    testState.machine = { result: { sampling: true } };
    expect(renderToStaticMarkup(<MachinePage />)).toContain("Sampling the machine…");

    testState.machine = { result: { hooks: "many" } };
    expect(renderToStaticMarkup(<MachinePage />)).toContain("could not be read");
  });

  it("says so when the build has no machine verb, and when there is no adapter", () => {
    testState.snapshot = { ...readySnapshot, commands: [] };
    expect(renderToStaticMarkup(<MachinePage />)).toContain(
      "This Infinitus build has no machine verb.",
    );

    testState.capability = undefined;
    expect(renderToStaticMarkup(<MachinePage />)).toContain("no Infinitus adapter");
  });

  it("shows the offline state from the snapshot", () => {
    testState.snapshot = {
      available: false,
      unavailableReason: "socket gone",
      fleets: [],
      sessions: [],
      commands: [],
    };
    expect(renderToStaticMarkup(<MachinePage />)).toContain("offline: socket gone");
  });
});
