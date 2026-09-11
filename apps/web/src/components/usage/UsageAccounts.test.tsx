import {
  EnvironmentId,
  UsageDay,
  USAGE_CONTRACT_VERSION,
  type UsageSummary,
} from "@t3tools/contracts";
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vite-plus/test";

const testState = vi.hoisted(() => ({
  capability: true as boolean | undefined,
  primary: "primary" as string | null,
}));

vi.mock("@effect/atom-react", () => ({
  useAtomValue: () => ({ environment: { capabilities: { infinitus: testState.capability } } }),
}));
vi.mock("../../state/environments", () => ({ usePrimaryEnvironmentId: () => testState.primary }));
vi.mock("../../state/server", () => ({ primaryServerConfigAtom: { label: "config-atom" } }));
vi.mock("../ui/tooltip", () => ({
  Tooltip: "div",
  TooltipTrigger: "span",
  TooltipPopup: "span",
}));

import { UsageAccountsSection } from "./UsageAccounts";

const totals = {
  uncachedInputTokens: 100,
  cachedInputTokens: 1_000,
  cacheCreationTokens: 10,
  outputTokens: 50,
  reasoningTokens: 0,
};

const summary = (accounts: UsageSummary["accounts"]): UsageSummary => ({
  contractVersion: USAGE_CONTRACT_VERSION,
  readAt: "2026-08-11T12:37:00.000Z",
  sinceDay: UsageDay.make("2026-08-10"),
  untilDay: UsageDay.make("2026-08-11"),
  timeZone: "UTC",
  buckets: [],
  sources: [],
  pricing: { status: "fresh", source: "test", fetchedAt: null, knownModels: 1 },
  scanDurationMs: 1,
  ...(accounts === undefined ? {} : { accounts }),
});

const environment = (id: string, accounts: UsageSummary["accounts"]) => ({
  environmentId: EnvironmentId.make(id),
  label: id,
  isPending: false,
  error: null,
  summary: summary(accounts),
});

const attributed: NonNullable<UsageSummary["accounts"]> = {
  lines: [
    { email: "one@example.invalid", label: "work", number: 1, totals, costUsd: 3, records: 4 },
    { email: "two@example.invalid", label: "two@example.invalid", totals, costUsd: 1, records: 1 },
  ],
  unattributed: { totals, costUsd: 0.5, records: 2 },
  notClaude: { costUsd: 2, records: 3 },
  switchesInWindow: 3,
  basis: "swapd history",
};

function render(environments: ReturnType<typeof environment>[]): string {
  return renderToStaticMarkup(<UsageAccountsSection environments={environments} />);
}

beforeEach(() => {
  testState.capability = true;
  testState.primary = "primary";
});

describe("UsageAccountsSection", () => {
  it("lists each account with its share of the attributed cost, then the unattributed row", () => {
    const html = render([environment("other", undefined), environment("primary", attributed)]);

    expect(html).toContain("By account");
    expect(html.indexOf("work")).toBeLessThan(html.indexOf("two@example.invalid"));
    expect(html).toContain("$3.00");
    expect(html).toContain("75%");
    expect(html).toContain("25%");
    expect(html).toContain("Unattributed");
    expect(html).toContain("$0.50");
    expect(html).toContain("within a swap");
    expect(html).toContain("3 swaps");
    expect(html).toContain("swapd history");
    expect(html).toContain("not billing");
  });

  it("names the other providers' share so the table reconciles with the page", () => {
    expect(render([environment("primary", attributed)])).toContain("$2.00");
  });

  it("says so when the window holds no Claude records at all", () => {
    const html = render([
      environment("primary", {
        ...attributed,
        lines: [],
        unattributed: { totals, costUsd: 0, records: 0 },
        switchesInWindow: 1,
      }),
    ]);
    expect(html).toContain("No Claude records in this window.");
    expect(html).toContain("1 swap in this window");
    expect(html).not.toContain("<table");
  });

  it("renders nothing when the primary environment has no attribution", () => {
    expect(render([environment("primary", undefined)])).toBe("");
    expect(render([environment("other", attributed)])).toBe("");
  });

  it("renders nothing without the Infinitus capability", () => {
    testState.capability = undefined;
    expect(render([environment("primary", attributed)])).toBe("");
  });
});
