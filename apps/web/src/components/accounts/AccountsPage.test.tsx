import { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import type { ReactNode } from "react";
import { act, cloneElement, isValidElement, type ComponentProps } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { beforeEach, describe, expect, it, vi } from "vite-plus/test";

const environmentId = EnvironmentId.make("test-environment");

const testState = vi.hoisted(() => ({
  snapshot: null as InfinitusSnapshot | null,
  command: vi.fn(),
  refresh: vi.fn(),
}));

vi.mock("../../env", () => ({ isElectron: false }));
vi.mock("@effect/atom-react", () => ({
  useAtomValue: () =>
    new Map([["test-environment", { environment: { capabilities: { infinitus: true } } }]]),
}));
vi.mock("../../state/environments", () => ({
  useEnvironments: () => ({
    environments: [{ environmentId: "test-environment", label: "Test environment" }],
  }),
  usePrimaryEnvironmentId: () => "test-environment",
}));
vi.mock("../../state/infinitus", () => ({
  infinitusEnvironment: {
    snapshot: () => ({ label: "snapshot-atom" }),
    command: { label: "command-atom" },
  },
}));
vi.mock("../../state/query", () => ({
  useEnvironmentQuery: () => ({
    data: testState.snapshot,
    error: null,
    isPending: testState.snapshot === null,
    isSuccess: testState.snapshot !== null,
    refresh: testState.refresh,
  }),
}));
vi.mock("../../state/server", () => ({ environmentServerConfigsAtom: { label: "configs-atom" } }));
vi.mock("../../state/use-atom-command", () => ({ useAtomCommand: () => testState.command }));
vi.mock("../../hooks/useSettings", () => ({
  usePrimarySettings: (selector: (settings: { timestampFormat: string }) => unknown) =>
    selector({ timestampFormat: "24-hour" }),
}));
vi.mock("../ui/badge", () => ({ Badge: "span" }));
vi.mock("../ui/button", () => ({ Button: "button" }));
vi.mock("../ui/input", () => ({ Input: "input" }));
vi.mock("../ui/menu", () => ({
  Menu: "div",
  MenuPopup: "div",
  MenuRadioGroup: "div",
  MenuRadioItem: "div",
  MenuTrigger: "button",
}));
vi.mock("../ui/scroll-area", () => ({ ScrollArea: "div" }));
vi.mock("../ui/sidebar", () => ({ SidebarInset: "div" }));
vi.mock("../ui/skeleton", () => ({ Skeleton: "div" }));
vi.mock("../ui/spinner", () => ({ Spinner: () => null }));
vi.mock("../ui/tooltip", () => ({
  Tooltip: ({ children }: { children: ReactNode }) => children,
  TooltipTrigger: ({
    render,
    children,
  }: ComponentProps<typeof import("../ui/tooltip").TooltipTrigger>) =>
    isValidElement(render) ? cloneElement(render, undefined, children) : <>{children}</>,
  TooltipPopup: () => null,
}));
vi.mock("../WorkspaceBreadcrumb", () => ({
  WorkspaceBreadcrumb: "div",
  WorkspaceBreadcrumbItem: "div",
  WorkspaceBreadcrumbSeparator: "span",
}));
vi.mock("../WorkspacePageContainer", () => ({ WorkspacePageContainer: "main" }));
vi.mock("../WorkspacePageHeader", () => ({ WorkspacePageHeader: "header" }));

import { AccountsPage } from "./AccountsPage";

const account = (overrides: Partial<InfinitusSnapshot["fleets"][number]["accounts"][number]>) => ({
  number: 1,
  email: "one@example.com",
  active: false,
  isOrganization: false,
  usageStatus: "ok",
  ...overrides,
});

const readySnapshot: InfinitusSnapshot = {
  available: true,
  fleets: [
    {
      key: "claude",
      engineID: "cswap",
      provider: "Claude",
      capabilities: ["switch", "hold", "prefer", "rename"],
      caveat: "Usage readings lag the engine by a minute.",
      activeNumber: 1,
      nextCandidate: 2,
      accounts: [
        account({
          number: 1,
          email: "one@example.com",
          plan: "Max 20x",
          active: true,
          preferred: false,
          usageAgeSeconds: 30,
          usage: {
            fiveHour: { name: "5h", pct: 68, countdown: "2h 14m" },
            sevenDay: { name: "7d", pct: 41 },
          },
        }),
        account({
          number: 2,
          email: "two@example.com",
          alias: "spare",
          disabled: true,
          preferred: false,
          usageStatus: "error",
        }),
      ],
    },
    {
      key: "proxy",
      engineID: "cliproxy",
      provider: "OpenAI",
      capabilities: [],
      accounts: [account({ number: 7, email: "seven@example.com", usageAgeSeconds: 7_200 })],
    },
  ],
  sessions: [],
  commands: [],
  forecast: {
    forecast: {
      basis: "run rate",
      computedAt: Date.now() / 1000 - 120,
      allDeadAt: Date.now() / 1000 + 7_200,
      drainOrder: [1, 2],
    },
  },
};

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  testState.snapshot = null;
  testState.command = vi.fn().mockResolvedValue({ _tag: "Success", value: {} });
  testState.refresh = vi.fn();
});

describe("AccountsPage", () => {
  it("names the socket and offers a retry when Infinitus is offline", () => {
    testState.snapshot = {
      available: false,
      unavailableReason: "No Infinitus is listening on this host.",
      status: {
        version: "1.0",
        sha: "abc",
        socket: "/tmp/infinitus.sock",
        badge: "",
        playground: false,
        signInRunning: false,
        engines: {},
      },
      fleets: [],
      sessions: [],
      commands: [],
    };

    const markup = renderToStaticMarkup(<AccountsPage />);

    expect(markup).toContain("Infinitus is offline");
    expect(markup).toContain("No Infinitus is listening on this host.");
    expect(markup).toContain("/tmp/infinitus.sock");
    expect(markup).toContain("Retry");
  });

  it("says so when the host reports no engines", () => {
    testState.snapshot = { available: true, fleets: [], sessions: [], commands: [] };

    const markup = renderToStaticMarkup(<AccountsPage />);

    expect(markup).toContain("No engines report accounts on this host.");
  });

  it("draws every fleet with its accounts, badges, windows and forecast", () => {
    testState.snapshot = readySnapshot;

    const markup = renderToStaticMarkup(<AccountsPage />);

    expect(markup).toContain("Claude");
    expect(markup).toContain("OpenAI (cliproxy)");
    expect(markup).toContain("Usage readings lag the engine by a minute.");
    expect(markup).toContain("one@example.com");
    expect(markup).toContain("Max 20x");
    expect(markup).toContain("68% used");
    expect(markup).toContain("resets in 2h 14m");
    expect(markup).toContain("updated just now");
    expect(markup).toContain("Active");
    expect(markup).toContain("Next");
    expect(markup).toContain("Held");
    expect(markup).toContain("All accounts exhausted by");
    expect(markup).toContain("one@example.com → spare");
  });

  it("drops the freshness line on a held account with no reading", () => {
    testState.snapshot = readySnapshot;

    const markup = renderToStaticMarkup(<AccountsPage />);

    expect(markup).toContain("Held");
    expect(markup).not.toContain("usage unavailable");
  });

  it("keeps the freshness line on an account that has no reading and is not held", () => {
    testState.snapshot = {
      ...readySnapshot,
      fleets: [
        {
          ...readySnapshot.fleets[1]!,
          accounts: [account({ number: 7, email: "seven@example.com", usageStatus: "error" })],
        },
      ],
    };

    const markup = renderToStaticMarkup(<AccountsPage />);

    expect(markup).toContain("usage unavailable");
  });

  it("sends switch for the row's fleet and account number", async () => {
    testState.snapshot = readySnapshot;
    let renderer!: ReactTestRenderer;
    await act(async () => {
      renderer = create(<AccountsPage />);
    });
    const button = renderer.root.findAll((node) => node.props["aria-label"] === "Switch spare")[0]!;

    await act(async () => {
      button.props.onClick();
    });

    expect(testState.command).toHaveBeenCalledWith({
      environmentId,
      input: { command: "switch", args: ["claude", "2"], options: {} },
    });
    renderer.unmount();
  });
});
