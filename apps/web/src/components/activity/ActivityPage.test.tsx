import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vite-plus/test";

const testState = vi.hoisted(() => ({
  snapshot: null as InfinitusSnapshot | null,
  events: null as { result?: unknown } | null,
  capability: true as boolean | undefined,
  showPolls: false,
  refresh: vi.fn(),
}));

const NOW_ISO = "2026-09-11T12:00:00.000Z";

vi.mock("../../env", () => ({ isElectron: false }));
vi.mock("@effect/atom-react", () => ({
  useAtomValue: () => ({ environment: { capabilities: { infinitus: testState.capability } } }),
}));
vi.mock("../../hooks/useLocalStorage", () => ({
  useLocalStorage: () => [testState.showPolls, vi.fn()],
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
    events: () => ({ label: "events-atom" }),
  },
}));
vi.mock("../../state/query", () => ({
  useEnvironmentQuery: (atom: { label: string } | null) => {
    const data =
      atom?.label === "events-atom" ? testState.events : atom === null ? null : testState.snapshot;
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

import { ActivityPage } from "./ActivityPage";

const readySnapshot: InfinitusSnapshot = {
  available: true,
  fleets: [],
  sessions: [],
  commands: [
    { name: "events", args: [], options: ["limit"], effect: "read", summary: "", replyShape: "" },
  ],
};

beforeEach(() => {
  testState.snapshot = null;
  testState.events = null;
  testState.capability = true;
  testState.showPolls = false;
  testState.refresh = vi.fn();
});

const pollRows = [
  {
    at: "2026-09-11T11:58:00Z",
    icon: "clock.arrow.circlepath",
    text: "poll",
    kind: "other",
    id: "P",
  },
  {
    at: "2026-09-11T11:58:01Z",
    icon: "hand.raised",
    text: "no switch — already consuming soonest",
    kind: "other",
    id: "N",
  },
];

describe("ActivityPage", () => {
  it("lists the log newest first under day headings with kind chips", () => {
    testState.snapshot = readySnapshot;
    testState.events = {
      result: [
        {
          at: "2026-09-10T09:00:00Z",
          icon: "arrow",
          text: "switched to spare",
          kind: "switch",
          id: "A",
        },
        {
          at: "2026-09-11T02:44:12Z",
          icon: "play.circle",
          text: "resumed 965c1ba7",
          kind: "nudge",
          id: "B",
        },
      ],
    };

    const markup = renderToStaticMarkup(<ActivityPage />);

    expect(markup).toContain("newest first");
    expect(markup.indexOf("resumed 965c1ba7")).toBeLessThan(markup.indexOf("switched to spare"));
    expect(markup).toContain(">nudge<");
    expect(markup).toContain(">switch<");
    expect(markup).toContain("Today");
    expect(markup).toContain("Yesterday");
  });

  it("hides the poller's lines until Show polls is on, and says so when they are all there is", () => {
    testState.snapshot = readySnapshot;
    testState.events = {
      result: [
        ...pollRows,
        { at: "2026-09-11T02:44:12Z", icon: "🔑", text: "phone paired", kind: "pairing", id: "K" },
      ],
    };
    let markup = renderToStaticMarkup(<ActivityPage />);
    expect(markup).toContain("phone paired");
    expect(markup).not.toContain("already consuming soonest");
    expect(markup).not.toContain(">poll<");
    expect(markup).toContain('aria-pressed="false"');

    testState.events = { result: pollRows };
    markup = renderToStaticMarkup(<ActivityPage />);
    expect(markup).toContain("Only polls so far");
    expect(markup).not.toContain("Nothing logged yet.");

    testState.showPolls = true;
    markup = renderToStaticMarkup(<ActivityPage />);
    expect(markup).toContain("already consuming soonest");
    expect(markup).toContain('aria-pressed="true"');
  });

  it("says so when the build has no events verb, when nothing is logged, and when offline", () => {
    testState.snapshot = { ...readySnapshot, commands: [] };
    expect(renderToStaticMarkup(<ActivityPage />)).toContain("no events verb");

    testState.snapshot = readySnapshot;
    testState.events = { result: [] };
    expect(renderToStaticMarkup(<ActivityPage />)).toContain("Nothing logged yet.");

    testState.snapshot = {
      available: false,
      unavailableReason: "socket gone",
      fleets: [],
      sessions: [],
      commands: [],
    };
    expect(renderToStaticMarkup(<ActivityPage />)).toContain("offline: socket gone");
  });
});
