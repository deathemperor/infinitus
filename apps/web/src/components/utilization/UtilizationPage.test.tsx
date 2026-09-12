import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vite-plus/test";

const testState = vi.hoisted(() => ({
  snapshot: null as InfinitusSnapshot | null,
  utilization: null as { result: unknown } | null,
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
    utilization: () => ({ label: "utilization-atom" }),
  },
}));
vi.mock("../../hooks/useLocalStorage", () => ({
  useLocalStorage: (_key: string, initial: unknown) => [initial, () => {}],
}));
vi.mock("../../state/query", () => ({
  useEnvironmentQuery: (atom: { label: string } | null) => {
    const data =
      atom === null
        ? null
        : atom.label === "utilization-atom"
          ? testState.utilization
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
vi.mock("../../hooks/useSettings", () => ({
  usePrimarySettings: (select: (settings: { timestampFormat: string }) => unknown) =>
    select({ timestampFormat: "24h" }),
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
vi.mock("../accounts/ForecastStrip", () => ({
  ForecastStrip: ({ forecast }: { forecast: { drainOrder: ReadonlyArray<string> } }) => (
    <p>strip: {forecast.drainOrder.join(" → ")}</p>
  ),
}));

import { UtilizationPage } from "./UtilizationPage";

const forecastVerb = {
  name: "forecast",
  args: [],
  options: [],
  effect: "read",
  summary: "",
  replyShape: "",
} as const;

const utilizationVerb = { ...forecastVerb, name: "utilization" } as const;

const inAnHour = Math.floor(Date.now() / 1000) + 3600;
const now = inAnHour - 3600;
const utilizationReply = {
  result: {
    days: 7,
    bucketSeconds: 1800,
    samples: [
      {
        t: now - 7200,
        email: "alpha@example.com",
        number: 1,
        fiveHour: { pct: 20 },
        sevenDay: { pct: 10 },
      },
      {
        t: now - 3600,
        email: "alpha@example.com",
        number: 1,
        active: true,
        fiveHour: { pct: 61 },
        sevenDay: { pct: 12 },
      },
      { t: now - 3600, email: "beta@example.com", number: 2, fiveHour: { pct: 100 } },
    ],
    windows: ["5h", "7d"],
    emails: ["alpha@example.com", "beta@example.com"],
    rates: {
      computedAt: now,
      lastHour: {
        input: 1000,
        output: 200,
        cacheRead: 5000,
        cacheWrite: 100,
        usd: 0.42,
        messages: 12,
      },
      lastDay: {
        input: 20_000,
        output: 4000,
        cacheRead: 90_000,
        cacheWrite: 1000,
        usd: 7.5,
        messages: 240,
      },
      lastWeek: { input: 100_000, output: 20_000, cacheRead: 400_000, usd: 31, messages: 1200 },
      files: 9,
      unpricedModels: ["mystery-1"],
    },
    liveRate: { perMinute: 1500, peakPerMinute: 4200 },
  },
};
const inADay = inAnHour + 86_400;

const readySnapshot: InfinitusSnapshot = {
  available: true,
  fleets: [
    {
      key: "swapd/claude",
      engineID: "swapd",
      provider: "claude",
      capabilities: [],
      activeNumber: 1,
      accounts: [
        {
          number: 1,
          email: "alpha@example.com",
          active: true,
          isOrganization: false,
          usageStatus: "ok",
        },
        {
          number: 2,
          email: "beta@example.com",
          alias: "beta",
          active: false,
          isOrganization: false,
          usageStatus: "ok",
        },
      ],
    },
  ],
  sessions: [],
  commands: [forecastVerb, utilizationVerb],
  forecast: {
    forecast: {
      basis: "5h pace measured over the last hour",
      computedAt: inAnHour - 3600,
      active: { number: 1 },
      allDeadAt: inADay,
      drainOrder: [1, 2],
      accounts: [
        {
          number: 1,
          email: "alpha@example.com",
          active: true,
          disabled: false,
          windows: [
            {
              name: "5h",
              pct: 61,
              ratePctPerHour: 39.2,
              resetsAt: inAnHour + 600,
              hitsAt: inAnHour,
            },
            { name: "7d", pct: 12, ratePctPerHour: 4.2, resetsAt: inADay, hitsAt: null },
            { name: "Fable", pct: 3, ratePctPerHour: null, resetsAt: null, hitsAt: null },
          ],
        },
        {
          number: 2,
          email: "beta@example.com",
          alias: "beta",
          active: false,
          disabled: true,
          windows: [{ name: "5h", pct: 100, ratePctPerHour: 0, resetsAt: inAnHour, hitsAt: null }],
        },
      ],
    },
  },
};

describe("UtilizationPage", () => {
  beforeEach(() => {
    testState.snapshot = readySnapshot;
    testState.utilization = utilizationReply;
    testState.capability = true;
    testState.refresh.mockReset();
  });

  it("charts every account's window over the range and tables the run rate (#747)", () => {
    const markup = renderToStaticMarkup(<UtilizationPage />);

    expect(markup).toContain("History");
    expect(markup).toContain("<polyline");
    expect(markup).toContain(">beta<");
    expect(markup).toContain("61%");
    expect(markup).toContain("100%");
    expect(markup).toContain("The 5h window of every account");
    expect(markup).toContain("Run rate");
    expect(markup).toContain("Last hour");
    expect(markup).toContain("6.3k");
    expect(markup).toContain("520.0k");
    expect(markup).toContain("31.00");
    expect(markup).toContain("Tokens counted but not priced: mystery-1");
    expect(markup).toContain("Live: 1.5k output tokens/min");
    expect(markup).toContain("24 hours");
  });

  it("waits for the scan, and says what a build without the verb is missing", () => {
    testState.utilization = { result: { days: 7, samples: [] } };
    let markup = renderToStaticMarkup(<UtilizationPage />);
    expect(markup).toContain("No history yet");
    expect(markup).toContain("Scanning transcripts");

    testState.snapshot = { ...readySnapshot, commands: [forecastVerb] };
    markup = renderToStaticMarkup(<UtilizationPage />);
    expect(markup).toContain("need a newer Infinitus app");
    expect(markup).not.toContain("Run rate");
  });

  it("renders every account's line with its windows, paces and the window that binds first", () => {
    const markup = renderToStaticMarkup(<UtilizationPage />);

    expect(markup).toContain("Forecast");
    expect(markup).toContain("alpha@example.com");
    expect(markup).toContain("Active");
    expect(markup).toContain("5h binds first");
    expect(markup).toContain("39%/h");
    expect(markup).toContain("4.2%/h");
    expect(markup).toContain("Pace unknown");
    expect(markup).toContain("Resets before it fills");
    expect(markup).toContain("Out ");
    expect(markup).toContain(">beta<");
    expect(markup).toContain("On Hold");
    expect(markup).toContain("No limit in sight");
    expect(markup).toContain("Estimate. 5h pace measured over the last hour");
    expect(markup).toContain("strip: alpha@example.com → beta");
  });

  it("says there is nothing to project yet when the app sent no lines", () => {
    testState.snapshot = { ...readySnapshot, forecast: { forecast: null } };
    const markup = renderToStaticMarkup(<UtilizationPage />);
    expect(markup).toContain("No projection yet");
    expect(markup).not.toContain("strip:");
  });

  it("says so when the build has no forecast verb, and when there is no adapter", () => {
    const { forecast: _forecast, ...noForecast } = readySnapshot;
    testState.snapshot = { ...noForecast, commands: [] };
    expect(renderToStaticMarkup(<UtilizationPage />)).toContain(
      "This Infinitus build has no forecast verb.",
    );

    testState.capability = undefined;
    expect(renderToStaticMarkup(<UtilizationPage />)).toContain("no Infinitus adapter");
  });

  it("shows the offline state from the snapshot", () => {
    testState.snapshot = {
      available: false,
      unavailableReason: "socket gone",
      fleets: [],
      sessions: [],
      commands: [],
    };
    expect(renderToStaticMarkup(<UtilizationPage />)).toContain("offline: socket gone");
  });
});
