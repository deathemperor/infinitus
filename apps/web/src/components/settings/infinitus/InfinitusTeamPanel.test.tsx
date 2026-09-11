import { InfinitusCommandFailed, type InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import * as Redacted from "effect/Redacted";
import { act, StrictMode, type ReactNode } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

const { fake } = vi.hoisted(() => ({
  fake: {
    capability: undefined as boolean | undefined,
    snapshot: null as InfinitusSnapshot | null,
    run: vi.fn(),
    secret: vi.fn(),
  },
}));

vi.mock("../../../state/environments", () => ({
  usePrimaryEnvironment: () => ({
    environmentId: "env-1",
    serverConfig: { environment: { capabilities: { infinitus: fake.capability } } },
  }),
}));
vi.mock("../../../state/infinitus", () => ({
  infinitusEnvironment: {
    snapshot: () => null,
    command: { label: "infinitus:command" },
    secret: { label: "infinitus:secret" },
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
vi.mock("../../../state/use-atom-command", () => ({
  useAtomCommand: (atom: { label: string }) =>
    atom.label === "infinitus:secret" ? fake.secret : fake.run,
}));
vi.mock("../../../hooks/useSettings", () => ({
  PRIMARY_SETTINGS_UNAVAILABLE_MESSAGE: "Connect to an environment",
  usePrimarySettingsAvailable: () => true,
}));
vi.mock("../settingsLayout", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../settingsLayout")>()),
  SettingsPageContainer: ({ children }: { children: ReactNode }) => children,
}));

import { InfinitusTeamPanel } from "./InfinitusTeamPanel";

const TEAM_COMMANDS = [
  { name: "team-status" },
  { name: "team-join", stdin: "secret" },
  { name: "team-create", stdin: "secret" },
  { name: "team-hostname", stdin: "secret" },
  { name: "team-approve" },
].map((entry) => ({
  args: [],
  options: [],
  effect: "write" as const,
  summary: "",
  replyShape: "",
  ...entry,
}));

function snapshot(
  commands: ReadonlyArray<{ readonly name: string }> = TEAM_COMMANDS,
): InfinitusSnapshot {
  return { available: true, fleets: [], sessions: [], commands } as unknown as InfinitusSnapshot;
}

const TEAM = {
  id: "t1",
  name: "Alpha",
  remote: "github.com/…/alpha",
  kid: "k-me",
  role: "leader",
  members: [
    { kid: "k-me", name: "Me", role: "leader", isMe: true, sessionsNow: 1, blockers: [] },
    { kid: "k-2", name: "Bo", role: "member", isMe: false, sessionsNow: 0, blockers: [] },
  ],
  requests: [{ kid: "k-3", name: "Cy", platform: "macOS", devices: ["MBP"], at: 1_699_999_000 }],
  lastFetch: null,
  lastPublish: null,
  lastError: null,
};

const ok = (result: unknown) => ({ _tag: "Success", value: { result } });

let renderer: ReactTestRenderer | undefined;

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  fake.capability = true;
  fake.snapshot = snapshot();
  fake.run = vi.fn().mockResolvedValue(ok(TEAM));
  fake.secret = vi.fn().mockResolvedValue(ok(TEAM));
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
        <InfinitusTeamPanel />
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

describe("InfinitusTeamPanel", () => {
  it("reads team-status and draws the roster and a leader's requests", async () => {
    await renderPanel();
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "team-status", args: [], options: {} },
    });
    const output = rendered();
    expect(output).toContain("Alpha");
    expect(output).toContain("Bo");
    expect(output).toContain("Cy");
    expect(output).not.toContain("Join a team");
  });

  it("approves a request by kid", async () => {
    await renderPanel();
    await act(async () => {
      (byLabel("Approve Cy").props as { onClick: () => void }).onClick();
    });
    expect(fake.run).toHaveBeenLastCalledWith({
      environmentId: "env-1",
      input: { command: "team-approve", args: ["k-3"], options: {} },
    });
  });

  it("offers Join with no team and sends the code on the secret channel only", async () => {
    fake.run = vi.fn().mockResolvedValue(ok(null));
    await renderPanel();
    expect(rendered()).toContain("This Mac is not in a team.");
    await act(async () => {
      (byLabel("Your name").props as { onChange: (event: unknown) => void }).onChange({
        currentTarget: { value: "Alice" },
      });
    });
    await act(async () => {
      (
        byLabel("Team code or invite link").props as { onChange: (event: unknown) => void }
      ).onChange({ currentTarget: { value: "infinitus://join/abc" } });
    });
    const form = renderer!.root.findAll((node) => node.type === "form")[0]!;
    await act(async () => {
      (form.props as { onSubmit: (event: unknown) => void }).onSubmit({
        preventDefault: () => undefined,
      });
    });
    expect(fake.secret).toHaveBeenCalledTimes(1);
    const input = fake.secret.mock.calls[0]![0] as {
      input: { command: string; args: Record<string, string>; secret: Redacted.Redacted<string> };
    };
    expect(input.input.command).toBe("team-join");
    expect(input.input.args).toEqual({ "your name": "Alice" });
    expect(Redacted.value(input.input.secret)).toBe("infinitus://join/abc");
    expect(rendered()).not.toContain("infinitus://join/abc");
    expect(rendered()).toContain("Alpha");
  });

  it("shows the Mac's join error verbatim without the code", async () => {
    fake.run = vi.fn().mockResolvedValue(ok(null));
    fake.secret = vi.fn().mockResolvedValue({
      _tag: "Failure",
      cause: Cause.fail(
        new InfinitusCommandFailed({
          command: "team-join",
          error: "that code has expired",
          restarting: false,
        }),
      ),
    });
    await renderPanel();
    await act(async () => {
      (byLabel("Your name").props as { onChange: (event: unknown) => void }).onChange({
        currentTarget: { value: "Alice" },
      });
    });
    await act(async () => {
      (
        byLabel("Team code or invite link").props as { onChange: (event: unknown) => void }
      ).onChange({ currentTarget: { value: "secret-code" } });
    });
    const form = renderer!.root.findAll((node) => node.type === "form")[0]!;
    await act(async () => {
      (form.props as { onSubmit: (event: unknown) => void }).onSubmit({
        preventDefault: () => undefined,
      });
    });
    const output = rendered();
    expect(output).toContain("that code has expired");
    expect(output).not.toContain("secret-code");
  });

  async function fillCreate(token: string) {
    const type = (label: string, value: string) =>
      act(async () => {
        (byLabel(label).props as { onChange: (event: unknown) => void }).onChange({
          currentTarget: { value },
        });
      });
    await type("Team name", "Alpha");
    await type("Your name as leader", "Me");
    await type("Empty private repo URL", "https://host/o/r.git");
    if (token !== "") await type("Write token (optional)", token);
    // The create form is the second form on the page (Join comes first).
    const createForm = renderer!.root.findAll((node) => node.type === "form")[1]!;
    await act(async () => {
      (createForm.props as { onSubmit: (event: unknown) => void }).onSubmit({
        preventDefault: () => undefined,
      });
    });
  }

  it("creates a team with a token on the secret channel only", async () => {
    fake.run = vi.fn().mockResolvedValue(ok(null));
    await renderPanel();
    await fillCreate("ghp_secret");
    expect(fake.secret).toHaveBeenCalledTimes(1);
    const input = fake.secret.mock.calls[0]![0] as {
      input: { command: string; args: Record<string, string>; secret: Redacted.Redacted<string> };
    };
    expect(input.input.command).toBe("team-create");
    expect(input.input.args).toEqual({ name: "Alpha", remote: "https://host/o/r.git", as: "Me" });
    expect(Redacted.value(input.input.secret)).toBe("ghp_secret");
    expect(rendered()).not.toContain("ghp_secret");
    expect(rendered()).toContain("Alpha");
  });

  it("creates a team without a token over the plain command", async () => {
    fake.run = vi
      .fn()
      .mockResolvedValueOnce(ok(null))
      .mockResolvedValueOnce(ok(null))
      .mockResolvedValue(ok(TEAM));
    await renderPanel();
    await fillCreate("");
    expect(fake.secret).not.toHaveBeenCalled();
    expect(fake.run).toHaveBeenLastCalledWith({
      environmentId: "env-1",
      input: {
        command: "team-create",
        args: ["Alpha"],
        options: { remote: "https://host/o/r.git", as: "Me" },
      },
    });
    expect(rendered()).toContain("Alpha");
  });

  it("saves the zone and label with the Cloudflare token on the secret channel, then forgets it plainly", async () => {
    fake.secret = vi
      .fn()
      .mockResolvedValue(ok({ zone: "example.com", label: "team", configured: true }));
    await renderPanel();
    const type = (label: string, value: string) =>
      act(async () => {
        (byLabel(label).props as { onChange: (event: unknown) => void }).onChange({
          currentTarget: { value },
        });
      });
    await type("Zone", "example.com");
    await type("Label", "team");
    await type("Cloudflare API token", "cf_secret");
    const form = renderer!.root.findAll((node) => node.type === "form")[0]!;
    await act(async () => {
      (form.props as { onSubmit: (event: unknown) => void }).onSubmit({
        preventDefault: () => undefined,
      });
    });
    const input = fake.secret.mock.calls[0]![0] as {
      input: { command: string; args: Record<string, string>; secret: Redacted.Redacted<string> };
    };
    expect(input.input.command).toBe("team-hostname");
    expect(input.input.args).toEqual({ zone: "example.com", label: "team" });
    expect(Redacted.value(input.input.secret)).toBe("cf_secret");
    let output = rendered();
    expect(output).not.toContain("cf_secret");
    expect(output).toContain("Cloudflare zone example.com · label team");
    // The page keeps the command it took at render, so the same fn answers.
    fake.run.mockResolvedValue(ok({ zone: null, label: null, configured: false }));
    const forget = renderer!.root.findAll(
      (node) =>
        typeof node.type !== "string" &&
        (node.props as { children?: unknown }).children === "Forget token" &&
        typeof (node.props as { onClick?: unknown }).onClick === "function",
    )[0]!;
    await act(async () => {
      (forget.props as { onClick: () => void }).onClick();
    });
    expect(fake.run).toHaveBeenLastCalledWith({
      environmentId: "env-1",
      input: { command: "team-hostname", args: [], options: { clear: "true" } },
    });
    output = rendered();
    expect(output).not.toContain("Cloudflare zone example.com");
  });

  it("refuses on a build without team-status", async () => {
    fake.snapshot = snapshot([{ name: "prefs" }]);
    await renderPanel();
    expect(rendered()).toContain("no team commands");
    expect(fake.run).not.toHaveBeenCalled();
  });
});
