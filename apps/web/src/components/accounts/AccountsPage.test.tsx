import { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import type { ReactNode } from "react";
import { act, cloneElement, isValidElement, type ComponentProps } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import * as Redacted from "effect/Redacted";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { beforeEach, describe, expect, it, vi } from "vite-plus/test";

const environmentId = EnvironmentId.make("test-environment");

const testState = vi.hoisted(() => ({
  snapshot: null as InfinitusSnapshot | null,
  command: vi.fn(),
  refresh: vi.fn(),
}));

vi.mock("../../env", () => ({ isElectron: false }));
vi.mock("./signIn.logic", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./signIn.logic")>()),
  SIGN_IN_POLL_MS: 0,
}));
vi.mock("@effect/atom-react", () => ({
  useAtomValue: () =>
    new Map([["test-environment", { environment: { capabilities: { infinitus: true } } }]]),
}));
vi.mock("../../state/environments", () => ({
  useEnvironments: () => ({
    environments: [{ environmentId: "test-environment", label: "Test environment" }],
  }),
  usePrimaryEnvironmentId: () => "test-environment",
  usePrimaryEnvironment: () => ({
    environmentId: "test-environment",
    serverConfig: {
      environment: {
        capabilities: { infinitus: true },
        platform: { os: "darwin", arch: "arm64" },
      },
    },
  }),
}));
vi.mock("../../state/infinitus", () => ({
  infinitusEnvironment: {
    snapshot: () => ({ label: "snapshot-atom" }),
    command: { label: "command-atom" },
    launch: { label: "launch-atom" },
    secret: { label: "secret-atom" },
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
const NOW_ISO = "2026-09-11T10:00:00.000Z";
vi.mock("../../hooks/useNowMinute", () => ({ useNowMinute: () => NOW_ISO }));
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
      engineID: "swapd",
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
    // The server is a Mac, so the offline card can also open the app (#654).
    expect(markup).toContain("Launch Infinitus");
  });

  it("says what is missing when the host reports no engines", () => {
    testState.snapshot = { available: true, fleets: [], sessions: [], commands: [] };

    const markup = renderToStaticMarkup(<AccountsPage />);

    expect(markup).toContain("No accounts yet");
    expect(markup).toContain("This Mac reports no engine at all.");
    expect(markup).toContain("Open Engines");
    expect(markup).toContain("Set up an engine");
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

  it("carries the exhausted band on a fleet whose every unheld account is at a limit", () => {
    const revivalAt = new Date(Date.parse(NOW_ISO) + 2 * 60 * 60 * 1000).toISOString();
    testState.snapshot = {
      ...readySnapshot,
      fleets: [
        {
          ...readySnapshot.fleets[0]!,
          accounts: [
            account({
              number: 1,
              email: "one@example.com",
              active: true,
              usage: { fiveHour: { pct: 100, resetsAt: revivalAt } },
            }),
            account({ number: 2, email: "two@example.com", alias: "spare", disabled: true }),
          ],
        },
      ],
    };

    const markup = renderToStaticMarkup(<AccountsPage />);

    expect(markup).toContain("All accounts exhausted · next revival ");
    expect(markup).toContain("(one@example.com)");
  });

  it("shows no exhausted band while an account has room", () => {
    testState.snapshot = readySnapshot;

    expect(renderToStaticMarkup(<AccountsPage />)).not.toContain("next revival");
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

  const addCommand: InfinitusSnapshot["commands"][number] = {
    name: "add",
    args: ["<fleet>"],
    options: [],
    effect: "human",
    summary: "",
    replyShape: "",
  };
  const addableSnapshot: InfinitusSnapshot = {
    ...readySnapshot,
    commands: [addCommand],
    fleets: [
      {
        ...readySnapshot.fleets[0]!,
        capabilities: [...readySnapshot.fleets[0]!.capabilities, "addOAuth"],
        accounts: [
          readySnapshot.fleets[0]!.accounts[0]!,
          account({
            number: 2,
            email: "two@example.com",
            alias: "spare",
            usageStatus: "relogin_required",
          }),
        ],
      },
      readySnapshot.fleets[1]!,
    ],
  };

  it("offers add account and re-login only where the build and the fleet allow it", () => {
    testState.snapshot = addableSnapshot;
    const markup = renderToStaticMarkup(<AccountsPage />);
    expect(markup).toContain("Add account: Claude (swapd)");
    expect(markup).not.toContain("Add account: OpenAI (cliproxy)");
    expect(markup).toContain("Sign in again as spare");

    // The same fleets on a build whose manifest has no `add` verb.
    testState.snapshot = { ...addableSnapshot, commands: [] };
    const older = renderToStaticMarkup(<AccountsPage />);
    expect(older).not.toContain("Add account");
    expect(older).not.toContain("Sign in again");
  });

  it("says a sign-in is already running and holds the buttons", () => {
    testState.snapshot = {
      ...addableSnapshot,
      status: {
        version: "1.0",
        sha: "abc",
        socket: "/tmp/infinitus.sock",
        badge: "",
        playground: false,
        signInRunning: true,
        engines: {},
      },
    };
    const markup = renderToStaticMarkup(<AccountsPage />);
    expect(markup).toContain("A sign-in is already running in Infinitus.");
    expect(markup).toContain(
      'aria-label="Add account: Claude (swapd)" aria-busy="true" disabled=""',
    );
  });

  it("starts the fleet's sign-in, then polls wait-add until the app says it ended", async () => {
    testState.snapshot = addableSnapshot;
    testState.command = vi
      .fn()
      .mockResolvedValueOnce({ _tag: "Success", value: { result: { started: true } } })
      .mockResolvedValueOnce({
        _tag: "Failure",
        cause: Cause.fail({ _tag: "InfinitusCommandFailed", error: "timed out after 5s" }),
      })
      .mockResolvedValueOnce({
        _tag: "Success",
        value: { result: { done: true, error: null, fleets: [] } },
      });
    let renderer!: ReactTestRenderer;
    await act(async () => {
      renderer = create(<AccountsPage />);
    });
    const button = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Add account: Claude (swapd)",
    )[0]!;

    await act(async () => {
      button.props.onClick();
    });

    expect(testState.command).toHaveBeenNthCalledWith(1, {
      environmentId,
      input: { command: "add", args: ["claude"], options: {} },
    });
    expect(testState.command).toHaveBeenNthCalledWith(2, {
      environmentId,
      input: { command: "wait-add", args: [], options: { timeout: "5" } },
    });
    expect(testState.command).toHaveBeenCalledTimes(3);
    const status = renderer.root.findAll((node) => node.props.role === "status")[0]!;
    expect(status.children.join("")).toBe("Sign-in finished.");
    renderer.unmount();
  });

  it("signs a lapsed account in again through the same verb, naming who to sign in as", async () => {
    testState.snapshot = addableSnapshot;
    testState.command = vi
      .fn()
      .mockResolvedValueOnce({ _tag: "Success", value: { result: { started: true } } })
      .mockReturnValue(new Promise(() => undefined));
    let renderer!: ReactTestRenderer;
    await act(async () => {
      renderer = create(<AccountsPage />);
    });
    const button = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Sign in again as spare",
    )[0]!;

    await act(async () => {
      button.props.onClick();
    });

    expect(testState.command).toHaveBeenNthCalledWith(1, {
      environmentId,
      input: { command: "add", args: ["claude"], options: {} },
    });
    const status = renderer.root.findAll((node) => node.props.role === "status")[0]!;
    expect(status.children.join("")).toBe("Sign-in running on the Mac — sign in as spare.");
    renderer.unmount();
  });

  it("surfaces the app's refusal to start a second sign-in", async () => {
    testState.snapshot = addableSnapshot;
    testState.command = vi.fn().mockResolvedValue({
      _tag: "Failure",
      cause: Cause.fail({ _tag: "InfinitusCommandFailed", error: "a sign-in is already running" }),
    });
    let renderer!: ReactTestRenderer;
    await act(async () => {
      renderer = create(<AccountsPage />);
    });
    const button = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Add account: Claude (swapd)",
    )[0]!;
    await act(async () => {
      button.props.onClick();
    });
    const status = renderer.root.findAll((node) => node.props.role === "status")[0]!;
    expect(status.children.join("")).toBe("Sign-in failed: a sign-in is already running");
    expect(testState.command).toHaveBeenCalledTimes(1);
    renderer.unmount();
  });

  const signInSnapshot: InfinitusSnapshot = {
    ...addableSnapshot,
    commands: [...addableSnapshot.commands, { ...addCommand, name: "signin-begin" }],
  };

  /** The desktop shell's sign-in methods on `window`, undone after the test. */
  const installBridge = (bridge: Record<string, unknown> | undefined) => {
    const host = globalThis as unknown as { window: Record<string, unknown> | undefined };
    const had = host.window;
    host.window = { ...had, desktopBridge: bridge };
    return () => {
      host.window = had;
    };
  };

  const bridgeStub = () => ({
    openInfinitusSignIn: vi.fn().mockResolvedValue(undefined),
    closeInfinitusSignIn: vi.fn().mockResolvedValue(undefined),
    submitInfinitusSignInCode: vi.fn().mockResolvedValue({ ok: true }),
  });

  it("without the shell, opens the page from a link and hands the code over infinitus.secret (#747)", async () => {
    const restore = installBridge(undefined);
    testState.snapshot = signInSnapshot;
    const begun = {
      flowId: "f1",
      url: "https://claude.ai/oauth",
      pasteCode: true,
      label: "Add account",
    };
    // The poll keeps asking while the test looks at the page, so answer by verb:
    // waiting for the code until it is submitted over the secret RPC, then done.
    let codeSubmitted = false;
    testState.command = vi.fn().mockImplementation(async (call: { input: { command: string } }) => {
      switch (call.input.command) {
        case "signin-begin":
          return { _tag: "Success", value: { result: begun } };
        case "signin-status":
          return {
            _tag: "Success",
            value: {
              result: codeSubmitted
                ? { flowId: "f1", phase: "done", pasteCode: true, account: "two@example.com" }
                : { flowId: "f1", phase: "waitingForCode", pasteCode: true },
            },
          };
        case "signin-code":
          codeSubmitted = true;
          return { _tag: "Success", value: { result: { ok: true } } };
        default:
          return { _tag: "Success", value: {} };
      }
    });
    let renderer!: ReactTestRenderer;
    await act(async () => {
      renderer = create(<AccountsPage />);
    });
    const button = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Add account: Claude (swapd)",
    )[0]!;
    await act(async () => {
      button.props.onClick();
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 5));
    });

    // No shell: the page is a link for this device to open.
    const link = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Open the sign-in page: Claude (swapd)",
    )[0]!;
    expect(link.props.href).toBe("https://claude.ai/oauth");
    expect(link.props.target).toBe("_blank");
    const field = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Sign-in code: Claude (swapd)",
    )[0]!;
    expect(field.props.type).toBe("password");
    expect(field.props.autoComplete).toBe("off");

    const section = renderer.root.findAll(
      (node) => node.props.signIn?.onSubmitCode !== undefined,
    )[0]!;
    await act(async () => {
      section.props.signIn.onSubmitCode("the-code");
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 10));
    });
    const codeCall = testState.command.mock.calls.find(
      (call) => (call[0] as { input: { command: string } }).input.command === "signin-code",
    )![0] as { environmentId: string; input: { args: unknown; secret: Redacted.Redacted<string> } };
    expect(codeCall.environmentId).toBe(environmentId);
    expect(codeCall.input.args).toEqual({ flowId: "f1" });
    expect(Redacted.value(codeCall.input.secret)).toBe("the-code");
    // The value never lands in the rendered page.
    expect(JSON.stringify(renderer.toJSON())).not.toContain("the-code");
    const status = renderer.root.findAll((node) => node.props.role === "status")[0]!;
    expect(status.children.join("")).toBe("Signed in as two@example.com.");
    renderer.unmount();
    restore();
  });

  it("runs the sign-in inside the app: begin, the shell's window, the pasted code, done", async () => {
    const bridge = bridgeStub();
    const restore = installBridge(bridge);
    testState.snapshot = signInSnapshot;
    const begun = {
      flowId: "f1",
      url: "https://claude.ai/oauth",
      pasteCode: true,
      label: "Add account",
    };
    testState.command = vi
      .fn()
      .mockResolvedValueOnce({ _tag: "Success", value: { result: begun } })
      .mockResolvedValueOnce({
        _tag: "Success",
        value: { result: { flowId: "f1", phase: "waitingForCode", pasteCode: true } },
      })
      .mockResolvedValueOnce({
        _tag: "Success",
        value: {
          result: { flowId: "f1", phase: "done", pasteCode: true, account: "two@example.com" },
        },
      })
      .mockResolvedValue({ _tag: "Success", value: {} });
    let renderer!: ReactTestRenderer;
    await act(async () => {
      renderer = create(<AccountsPage />);
    });
    const button = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Add account: Claude (swapd)",
    )[0]!;
    await act(async () => {
      button.props.onClick();
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 5));
    });

    expect(testState.command).toHaveBeenNthCalledWith(1, {
      environmentId,
      input: { command: "signin-begin", args: ["claude"], options: {} },
    });
    expect(bridge.openInfinitusSignIn).toHaveBeenCalledWith({
      flowId: "f1",
      url: "https://claude.ai/oauth",
      label: "Add account",
    });
    expect(testState.command).toHaveBeenNthCalledWith(2, {
      environmentId,
      input: { command: "signin-status", args: ["f1"], options: {} },
    });
    // The code field is up while the app waits for the paste; the code goes
    // to the shell, never through a command.
    const field = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Sign-in code: Claude (swapd)",
    );
    if (field.length > 0) {
      const form = renderer.root.findAll((node) => node.type === "form")[0]!;
      await act(async () => {
        form.props.onSubmit({
          preventDefault: () => {},
          currentTarget: { elements: { namedItem: () => null } },
        });
      });
    }
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 10));
    });
    expect(bridge.closeInfinitusSignIn).toHaveBeenCalledWith("f1");
    expect(testState.command).toHaveBeenNthCalledWith(4, {
      environmentId,
      input: { command: "refresh", args: [], options: {} },
    });
    const status = renderer.root.findAll((node) => node.props.role === "status")[0]!;
    expect(status.children.join("")).toBe("Signed in as two@example.com.");
    expect(
      testState.command.mock.calls.some(
        (call) => (call[0] as { input: { command: string } }).input.command === "signin-code",
      ),
    ).toBe(false);
    renderer.unmount();
    restore();
  });

  it("signs a lapsed account in again inside the app, naming its email to the app", async () => {
    const bridge = bridgeStub();
    const restore = installBridge(bridge);
    testState.snapshot = signInSnapshot;
    testState.command = vi
      .fn()
      .mockResolvedValueOnce({
        _tag: "Success",
        value: {
          result: {
            flowId: "f2",
            url: "https://x",
            pasteCode: false,
            label: "Sign in again — spare",
          },
        },
      })
      .mockReturnValue(new Promise(() => undefined));
    let renderer!: ReactTestRenderer;
    await act(async () => {
      renderer = create(<AccountsPage />);
    });
    const relogin = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Sign in again as spare",
    )[0]!;
    await act(async () => {
      relogin.props.onClick();
    });
    expect(testState.command).toHaveBeenNthCalledWith(1, {
      environmentId,
      input: { command: "signin-begin", args: ["claude"], options: { relogin: "two@example.com" } },
    });
    expect(bridge.openInfinitusSignIn).toHaveBeenCalledWith({
      flowId: "f2",
      url: "https://x",
      label: "Sign in again — spare",
    });
    const cancel = renderer.root.findAll(
      (node) => node.props["aria-label"] === "Cancel sign-in: Claude (swapd)",
    )[0]!;
    await act(async () => {
      cancel.props.onClick();
    });
    expect(bridge.closeInfinitusSignIn).toHaveBeenCalledWith("f2");
    expect(testState.command).toHaveBeenLastCalledWith({
      environmentId,
      input: { command: "signin-cancel", args: ["f2"], options: {} },
    });
    renderer.unmount();
    restore();
  });

  it("leaves the sign-ins section out when nothing lapsed", () => {
    testState.snapshot = readySnapshot;

    expect(renderToStaticMarkup(<AccountsPage />)).not.toContain("Sign-ins");
  });

  it("lists every lapsed profile under the fleets, even on a host with no fleets", () => {
    const awsLogins: NonNullable<InfinitusSnapshot["awsLogins"]> = [
      {
        profile: "dev",
        flow: "deviceCode",
        pid: 101,
        sessionLabel: "api · feature/login",
        failedAt: new Date(Date.now() - 2 * 3_600_000).toISOString(),
      },
      {
        profile: "me@example.com",
        provider: "gcloud",
        flow: "relay",
        pid: 202,
        sessionLabel: "web",
        failedAt: null,
        state: {
          profile: "me@example.com",
          flow: "local",
          phase: "waitingForBrowser",
          startedAt: 1,
        },
      },
    ];
    testState.snapshot = { ...readySnapshot, awsLogins };

    const markup = renderToStaticMarkup(<AccountsPage />);

    expect(markup.indexOf("Sign-ins")).toBeGreaterThan(markup.indexOf("OpenAI (cliproxy)"));
    expect(markup).toContain("dev");
    expect(markup).toContain("Lapsed 2h ago");
    expect(markup).toContain("Waiting: api · feature/login");
    expect(markup).toContain("Sign in: AWS dev");
    expect(markup).toContain("me@example.com");
    expect(markup).toContain("Waiting for the Mac&#x27;s browser…");
    expect(markup).not.toContain("Sign in: gcloud me@example.com");

    testState.snapshot = { available: true, fleets: [], sessions: [], commands: [], awsLogins };
    const empty = renderToStaticMarkup(<AccountsPage />);
    expect(empty).toContain("No accounts yet");
    expect(empty).toContain("Sign in: AWS dev");
  });

  it("starts a lapsed profile's sign-in scoped to its session", async () => {
    testState.snapshot = {
      ...readySnapshot,
      awsLogins: [
        { profile: "dev", flow: "deviceCode", pid: 101, failedAt: null },
        { profile: "legacy", flow: "relay", pid: 303, failedAt: null },
      ],
    };
    let renderer!: ReactTestRenderer;
    await act(async () => {
      renderer = create(<AccountsPage />);
    });
    const button = (label: string) =>
      renderer.root.findAll((node) => node.props["aria-label"] === label)[0]!;

    await act(async () => {
      button("Sign in: AWS dev").props.onClick();
    });
    await act(async () => {
      button("Sign in: AWS legacy").props.onClick();
    });

    expect(testState.command).toHaveBeenNthCalledWith(1, {
      environmentId,
      input: { command: "aws-login", args: ["dev"], options: { pid: "101" } },
    });
    expect(testState.command).toHaveBeenNthCalledWith(2, {
      environmentId,
      input: { command: "aws-login", args: ["legacy"], options: { local: "true", pid: "303" } },
    });
    renderer.unmount();
  });
});
