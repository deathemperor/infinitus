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

import { InfinitusProfilesPanel } from "./InfinitusProfilesPanel";

const PROFILE_COMMANDS = ["profiles", "profile-set", "profile-remove"].map((name) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
}));

function snapshot(
  commands: ReadonlyArray<{ readonly name: string }> = PROFILE_COMMANDS,
): InfinitusSnapshot {
  return {
    available: true,
    fleets: [],
    sessions: [],
    commands,
  } as unknown as InfinitusSnapshot;
}

let renderer: ReactTestRenderer | undefined;

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  fake.capability = true;
  fake.snapshot = snapshot();
  fake.run = vi.fn().mockResolvedValue({
    _tag: "Success",
    value: {
      result: {
        profiles: [
          { name: "review", cwd: "~/code/app", engine: "claude", allowTools: ["Edit", "Bash git"] },
          { name: "scratch" },
        ],
      },
    },
  });
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
        <InfinitusProfilesPanel />
      </StrictMode>,
    );
  });
}

function rendered(): string {
  return JSON.stringify(renderer!.toJSON());
}

describe("InfinitusProfilesPanel", () => {
  it("lists what the profiles command answered", async () => {
    await renderPanel();
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "profiles", args: [], options: {} },
    });
    const output = rendered();
    expect(output).toContain("review");
    expect(output).toContain("allows Edit, Bash git");
    expect(output).toContain("scratch");
  });

  it("refuses on a build whose manifest has no profile commands", async () => {
    fake.snapshot = snapshot([{ name: "prefs" }]);
    await renderPanel();
    expect(rendered()).toContain("no profile commands (needs ≥ a6a18a94d)");
    expect(fake.run).not.toHaveBeenCalled();
  });

  it("removes a profile by name and reads the list again", async () => {
    await renderPanel();
    // StrictMode mounts the effect twice, so the reads before the click are
    // counted rather than assumed.
    const readsBefore = fake.run.mock.calls.length;
    const remove = renderer!.root.findAll(
      (node) =>
        typeof node.type !== "string" &&
        (node.props as { "aria-label"?: string })["aria-label"] === "Remove review",
    )[0]!;
    await act(async () => {
      (remove.props as { onClick: () => void }).onClick();
    });
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "profile-remove", args: ["review"], options: {} },
    });
    // The write is followed by a fresh read.
    expect(fake.run.mock.calls.length).toBe(readsBefore + 2);
  });

  it("says what the app said when a write is refused", async () => {
    await renderPanel();
    fake.run.mockResolvedValueOnce({
      _tag: "Failure",
      cause: Cause.fail(
        new InfinitusCommandFailed({
          command: "profile-remove",
          error: "no such profile",
          restarting: false,
        }),
      ),
    });
    const remove = renderer!.root.findAll(
      (node) =>
        typeof node.type !== "string" &&
        (node.props as { "aria-label"?: string })["aria-label"] === "Remove scratch",
    )[0]!;
    await act(async () => {
      (remove.props as { onClick: () => void }).onClick();
    });
    expect(rendered()).toContain("no such profile");
  });
});
