import { InfinitusCommandFailed, type InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import { act, StrictMode, type ReactNode } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

const { fake } = vi.hoisted(() => ({
  fake: {
    capability: undefined as boolean | undefined,
    snapshot: null as InfinitusSnapshot | null,
    run: vi.fn(),
  },
}));

vi.mock("../../../state/environments", () => ({
  usePrimaryEnvironment: () => ({
    environmentId: "env-1",
    serverConfig: { environment: { capabilities: { infinitus: fake.capability } } },
  }),
}));
vi.mock("../../../state/infinitus", () => ({
  infinitusEnvironment: { snapshot: () => null, command: { label: "infinitus:command" } },
}));
vi.mock("../../../state/query", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../../state/query")>()),
  useEnvironmentQuery: () => ({
    data: fake.snapshot,
    error: null,
    isPending: false,
    isSuccess: true,
    refresh: () => undefined,
  }),
}));
vi.mock("../../../state/use-atom-command", () => ({ useAtomCommand: () => fake.run }));
vi.mock("../../../hooks/useSettings", () => ({
  PRIMARY_SETTINGS_UNAVAILABLE_MESSAGE: "Connect to an environment",
  usePrimarySettingsAvailable: () => true,
}));
vi.mock("../settingsLayout", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../settingsLayout")>()),
  SettingsPageContainer: ({ children }: { children: ReactNode }) => children,
}));

import { InfinitusLockPanel } from "./InfinitusLockPanel";

const LOCK_COMMANDS = ["lock-status", "lock", "unlock"].map((name) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
}));

function snapshot(
  commands: ReadonlyArray<{ readonly name: string }> = LOCK_COMMANDS,
): InfinitusSnapshot {
  return { available: true, fleets: [], sessions: [], commands } as unknown as InfinitusSnapshot;
}

const status = (enabled: boolean, locked: boolean, relock = "immediately") => ({
  _tag: "Success",
  value: { result: { enabled, locked, relock } },
});

let renderer: ReactTestRenderer | undefined;

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  fake.capability = true;
  fake.snapshot = snapshot();
  fake.run = vi.fn().mockResolvedValue(status(true, false, "5 min"));
});

afterEach(async () => {
  await act(() => renderer?.unmount());
  renderer = undefined;
  vi.unstubAllGlobals();
});

async function renderPanel() {
  await act(async () => {
    renderer = create(
      <StrictMode>
        <InfinitusLockPanel />
      </StrictMode>,
    );
  });
}

function rendered(): string {
  return JSON.stringify(renderer!.toJSON());
}

function byLabel(label: string) {
  return renderer!.root.findAll(
    (node) =>
      typeof node.type !== "string" &&
      (node.props as { "aria-label"?: string })["aria-label"] === label,
  )[0]!;
}

function byText(text: string) {
  return renderer!.root.findAll(
    (node) =>
      typeof node.type !== "string" &&
      (node.props as { children?: unknown }).children === text &&
      typeof (node.props as { onClick?: unknown }).onClick === "function",
  )[0]!;
}

describe("InfinitusLockPanel", () => {
  it("reads lock-status and draws the state", async () => {
    await renderPanel();
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "lock-status", args: [], options: {} },
    });
    const output = rendered();
    expect(output).toContain("After 5 minutes");
    expect(output).toContain("Unlocked");
    expect(output).toContain("Lock now");
  });

  it("refuses on a build whose manifest has no lock verbs", async () => {
    fake.snapshot = snapshot([{ name: "prefs" }]);
    await renderPanel();
    expect(rendered()).toContain("no lock commands");
    expect(fake.run).not.toHaveBeenCalled();
  });

  it("turns the lock on over the switch and shows the Mac's own error verbatim", async () => {
    fake.run = vi
      .fn()
      .mockResolvedValueOnce(status(false, false))
      .mockResolvedValueOnce(status(false, false))
      .mockResolvedValue({
        _tag: "Failure",
        cause: Cause.fail(
          new InfinitusCommandFailed({
            command: "lock",
            error: "the unlock prompt was cancelled",
            restarting: false,
          }),
        ),
      });
    await renderPanel();
    await act(async () => {
      (
        byLabel("Unlock with Touch ID or password").props as {
          onCheckedChange: (checked: boolean) => void;
        }
      ).onCheckedChange(true);
    });
    expect(fake.run).toHaveBeenLastCalledWith({
      environmentId: "env-1",
      input: { command: "lock", args: ["on"], options: {} },
    });
    expect(rendered()).toContain("the unlock prompt was cancelled");
  });

  it("turns a refused lock off into a confirm that sends --yes", async () => {
    fake.run = vi
      .fn()
      .mockResolvedValueOnce(status(true, false))
      .mockResolvedValueOnce(status(true, false))
      .mockResolvedValueOnce({
        _tag: "Failure",
        cause: Cause.fail(
          new InfinitusCommandFailed({
            command: "lock",
            error: "this Mac is in Alpha; lock off --yes turns the lock off anyway",
            restarting: false,
          }),
        ),
      })
      .mockResolvedValue(status(false, false));
    await renderPanel();
    await act(async () => {
      (
        byLabel("Unlock with Touch ID or password").props as {
          onCheckedChange: (checked: boolean) => void;
        }
      ).onCheckedChange(false);
    });
    expect(rendered()).toContain("You're in Alpha");
    await act(async () => {
      (byText("Turn off").props as { onClick: () => void }).onClick();
    });
    expect(fake.run).toHaveBeenLastCalledWith({
      environmentId: "env-1",
      input: { command: "lock", args: ["off"], options: { yes: "true" } },
    });
    expect(rendered()).not.toContain("You're in Alpha");
  });

  it("locks now and unlocks from the status row", async () => {
    fake.run = vi
      .fn()
      .mockResolvedValueOnce(status(true, false))
      .mockResolvedValueOnce(status(true, false))
      .mockResolvedValueOnce(status(true, true))
      .mockResolvedValue(status(true, false));
    await renderPanel();
    await act(async () => {
      (byText("Lock now").props as { onClick: () => void }).onClick();
    });
    expect(fake.run).toHaveBeenLastCalledWith({
      environmentId: "env-1",
      input: { command: "lock", args: ["now"], options: {} },
    });
    expect(rendered()).toContain("Locked");
    await act(async () => {
      (byText("Unlock").props as { onClick: () => void }).onClick();
    });
    expect(fake.run).toHaveBeenLastCalledWith({
      environmentId: "env-1",
      input: { command: "unlock", args: [], options: {} },
    });
  });
});
