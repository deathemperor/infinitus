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
    serverConfig: {
      environment: {
        capabilities: { infinitus: fake.capability },
        platform: { os: "darwin", arch: "arm64" },
      },
    },
  }),
}));
vi.mock("../../../state/infinitus", () => ({
  infinitusEnvironment: {
    snapshot: () => null,
    command: { label: "infinitus:command" },
    launch: { label: "infinitus:launch" },
  },
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
// Tooltips (the reset affordance's) reach into floating-ui, which wants a
// window the unit environment does not have.
vi.mock("../../ui/tooltip", () => ({
  Tooltip: ({ children }: { children: ReactNode }) => children,
  TooltipTrigger: ({ render }: { render?: ReactNode }) => render ?? null,
  TooltipPopup: () => null,
}));
vi.mock("../settingsLayout", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../settingsLayout")>()),
  SettingsPageContainer: ({ children }: { children: ReactNode }) => children,
}));

import { InfinitusPrefsPanel, RestartConfirmDialog } from "./InfinitusPrefsPanel";

const CATALOG = {
  sections: [{ slug: "display", name: "Display" }],
  prefs: [
    {
      key: "title_icon_only",
      type: "bool" as const,
      default: false,
      value: false,
      section: "display",
      effect: "live" as const,
    },
    {
      key: "popup_layout",
      type: "string" as const,
      default: "wide",
      value: "stacked",
      section: "display",
      effect: "live" as const,
      choices: ["wide", "stacked", "hstack"],
    },
    {
      key: "engine_cswap_enabled",
      type: "bool" as const,
      default: true,
      value: true,
      section: "display",
      effect: "restart" as const,
    },
  ],
};

function snapshot(
  overrides: {
    readonly available?: boolean;
    readonly unavailableReason?: string;
    // Explicitly absent is the case a build without the `prefs` command shows.
    readonly prefs?: typeof CATALOG | undefined;
  } = {},
): InfinitusSnapshot {
  return {
    available: true,
    fleets: [],
    sessions: [],
    commands: [],
    prefs: CATALOG,
    ...overrides,
  } as InfinitusSnapshot;
}

/** PREF_COPY's wording for `engine_cswap_enabled`, the restart-effect row. */
const CSWAP_LABEL = "cswap engine on (credential swap under Claude Code)";

let renderer: ReactTestRenderer | undefined;

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  fake.capability = true;
  fake.snapshot = snapshot();
  fake.run = vi.fn().mockResolvedValue({ _tag: "Success", value: { result: {} } });
});

afterEach(async () => {
  await act(() => renderer?.unmount());
  renderer = undefined;
  vi.unstubAllGlobals();
});

async function renderPanel() {
  await act(() => {
    renderer = create(
      <StrictMode>
        <InfinitusPrefsPanel sectionSlugs={["display"]} title="Infinitus" />
      </StrictMode>,
    );
  });
  return renderer!;
}

function rendered(): string {
  return JSON.stringify(renderer!.toJSON());
}

function control(label: string) {
  return renderer!.root.findAll(
    (node) =>
      typeof node.type !== "string" &&
      (node.props as { "aria-label"?: string })["aria-label"] === label,
  )[0]!;
}

describe("InfinitusPrefsPanel states", () => {
  it("says nothing to edit when the server reaches no Infinitus", async () => {
    fake.capability = undefined;
    await renderPanel();
    expect(rendered()).toContain("does not reach an Infinitus app");
  });

  it("waits while the first snapshot is still coming", async () => {
    fake.snapshot = null;
    await renderPanel();
    expect(rendered()).toContain("Reading the Infinitus app…");
  });

  it("names the reason the socket gave when the app is not answering", async () => {
    fake.snapshot = snapshot({
      available: false,
      unavailableReason: "no socket at /tmp/infinitus.sock",
      prefs: undefined,
    });
    await renderPanel();
    expect(rendered()).toContain("no socket at /tmp/infinitus.sock");
    // A Mac server can be asked to open the app from here (#654).
    expect(rendered()).toContain("Launch Infinitus");
  });

  it("offers no launch while the catalog is only loading", async () => {
    fake.snapshot = null;
    await renderPanel();
    expect(rendered()).not.toContain("Launch Infinitus");
  });

  it("says which build a preference catalog needs", async () => {
    fake.snapshot = snapshot({ prefs: undefined });
    await renderPanel();
    expect(rendered()).toContain("no preference catalog (needs ≥ a6a18a94d)");
  });

  it("draws the catalog's own rows and marks the ones off their default", async () => {
    await renderPanel();
    const output = rendered();
    expect(output).toContain("Show only the icon");
    expect(output).toContain("Popup layout");
    // popup_layout is "stacked" while the app's default is "wide".
    expect(output).toContain("Default: Wide rows");
  });
});

describe("InfinitusPrefsPanel writes", () => {
  it("sends prefs set with the value as JSON", async () => {
    await renderPanel();
    await act(async () => {
      (
        control("Show only the icon").props as { onCheckedChange: (next: boolean) => void }
      ).onCheckedChange(true);
    });
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "prefs", args: ["set", "title_icon_only", "true"], options: {} },
    });
  });

  it("never re-sends the value the row already shows", async () => {
    await renderPanel();
    await act(async () => {
      (
        control("Show only the icon").props as { onCheckedChange: (next: boolean) => void }
      ).onCheckedChange(false);
    });
    expect(fake.run).not.toHaveBeenCalled();
  });

  it("holds a restart-effect write until the relaunch is confirmed", async () => {
    await renderPanel();
    await act(async () => {
      (control(CSWAP_LABEL).props as { onCheckedChange: (next: boolean) => void }).onCheckedChange(
        false,
      );
    });
    expect(fake.run).not.toHaveBeenCalled();

    const dialog = renderer!.root.findByType(RestartConfirmDialog);
    expect(dialog.props.pending).not.toBeNull();
    await act(async () => {
      dialog.props.onConfirm();
    });
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "prefs", args: ["set", "engine_cswap_enabled", "false"], options: {} },
    });
  });

  it("shows the app's own refusal under the row", async () => {
    fake.run = vi.fn().mockResolvedValue({
      _tag: "Failure",
      cause: Cause.fail(
        new InfinitusCommandFailed({
          command: "prefs",
          error: "unknown pref title_icon_only",
          restarting: false,
        }),
      ),
    });
    await renderPanel();
    await act(async () => {
      (
        control("Show only the icon").props as { onCheckedChange: (next: boolean) => void }
      ).onCheckedChange(true);
    });
    expect(rendered()).toContain("unknown pref title_icon_only");
  });

  it("stops waiting for a relaunch the app refused to start", async () => {
    fake.run = vi.fn().mockResolvedValue({
      _tag: "Failure",
      cause: Cause.fail(
        new InfinitusCommandFailed({
          command: "prefs",
          error: "cswap is not installed",
          restarting: false,
        }),
      ),
    });
    await renderPanel();
    await act(async () => {
      (control(CSWAP_LABEL).props as { onCheckedChange: (next: boolean) => void }).onCheckedChange(
        false,
      );
    });
    await act(async () => {
      renderer!.root.findByType(RestartConfirmDialog).props.onConfirm();
    });
    const output = rendered();
    expect(output).toContain("cswap is not installed");
    expect(output).not.toContain("Infinitus is relaunching");
  });
});
