import { InfinitusSecretRefused, type InfinitusSnapshot } from "@t3tools/contracts/infinitus";
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
    runSecret: vi.fn(),
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
    atom.label === "infinitus:secret" ? fake.runSecret : fake.run,
}));
vi.mock("../../../hooks/useSettings", () => ({
  PRIMARY_SETTINGS_UNAVAILABLE_MESSAGE: "Connect to an environment",
  usePrimarySettingsAvailable: () => true,
}));
vi.mock("../settingsLayout", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../settingsLayout")>()),
  SettingsPageContainer: ({ children }: { children: ReactNode }) => children,
}));

import { InfinitusEngineSecrets } from "./InfinitusEngineSecrets";

const command = (name: string, stdin?: string) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
  ...(stdin === undefined ? {} : { stdin }),
});

const ENGINE_COMMANDS = [
  command("proxy"),
  command("proxy-key", "secret"),
  command("9router"),
  command("9router-password", "secret"),
];

function snapshot(commands: ReadonlyArray<unknown> = ENGINE_COMMANDS): InfinitusSnapshot {
  return { available: true, fleets: [], commands } as unknown as InfinitusSnapshot;
}

const reply = (result: unknown) => ({ _tag: "Success", value: { result } });

function answerReads(input: { command: string }) {
  switch (input.command) {
    case "proxy":
      return reply({ baseURL: "http://127.0.0.1:8317", keyPresent: true });
    case "9router":
      return reply({ baseURL: "http://10.0.0.5:20128", passwordPresent: false, error: "refused" });
    default:
      return reply({});
  }
}

let renderer: ReactTestRenderer | undefined;

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  fake.capability = true;
  fake.snapshot = snapshot();
  fake.run = vi.fn(async ({ input }: { input: { command: string } }) => answerReads(input));
  fake.runSecret = vi.fn().mockResolvedValue(reply({ restarting: true }));
});

afterEach(async () => {
  await act(() => renderer?.unmount());
  renderer = undefined;
  vi.unstubAllGlobals();
});

async function renderSection() {
  await act(async () => {
    renderer = create(
      <StrictMode>
        <InfinitusEngineSecrets />
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

async function type(label: string, value: string) {
  await act(async () => {
    byLabel(label).props.onChange({ target: { value } });
  });
}

describe("InfinitusEngineSecrets", () => {
  it("reads both engines and draws url, secret state and the engine's own error", async () => {
    await renderSection();
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "proxy", args: [], options: {} },
    });
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "9router", args: [], options: {} },
    });
    const output = rendered();
    expect(output).toContain("http://10.0.0.5:20128");
    expect(output).toContain("Key set.");
    expect(output).toContain("Password not set.");
    expect(output).toContain("refused");
  });

  it("refuses on a build whose manifest lacks the secret marker", async () => {
    fake.snapshot = snapshot([command("proxy"), command("proxy-key"), command("9router")]);
    await renderSection();
    expect(rendered()).toContain("no engine secret commands");
    expect(fake.run).not.toHaveBeenCalled();
  });

  it("saves over infinitus.secret with the url, clears the field and says the app relaunches", async () => {
    await renderSection();
    await type("9Router dashboard password", "hunter2");
    await type("9Router base URL", "http://10.0.0.5:20128");
    await act(async () => {
      byLabel("Save 9Router and relaunch").props.onClick();
    });
    expect(fake.runSecret).toHaveBeenCalledTimes(1);
    const call = fake.runSecret.mock.calls[0]![0] as {
      environmentId: string;
      input: { command: string; args: Record<string, string>; secret: Redacted.Redacted<string> };
    };
    expect(call.environmentId).toBe("env-1");
    expect(call.input.command).toBe("9router-password");
    expect(call.input.args).toEqual({ url: "http://10.0.0.5:20128" });
    expect(Redacted.value(call.input.secret)).toBe("hunter2");
    expect(byLabel("9Router dashboard password").props.value).toBe("");
    expect(rendered()).toContain("relaunching");
    expect(rendered()).not.toContain("hunter2");
  });

  it("forgets a stored key with an empty secret", async () => {
    await renderSection();
    await act(async () => {
      byLabel("Forget CLIProxyAPI key").props.onClick();
    });
    const call = fake.runSecret.mock.calls[0]![0] as {
      input: { command: string; secret: Redacted.Redacted<string> };
    };
    expect(call.input.command).toBe("proxy-key");
    expect(Redacted.value(call.input.secret)).toBe("");
  });

  it("shows the server's refusal verbatim and keeps the secret out of it", async () => {
    fake.runSecret = vi.fn().mockResolvedValue({
      _tag: "Failure",
      cause: Cause.fail(
        new InfinitusSecretRefused({
          command: "proxy-key",
          reason: "too_many_attempts",
          detail: "Too many attempts at proxy-key; wait a minute.",
        }),
      ),
    });
    await renderSection();
    await type("CLIProxyAPI management key", "sk-live");
    await act(async () => {
      byLabel("Save CLIProxyAPI and relaunch").props.onClick();
    });
    const output = rendered();
    expect(output).toContain("Too many attempts at proxy-key");
    expect(output).not.toContain("sk-live");
  });

  it("tells a client without the write scope who can change secrets", async () => {
    fake.runSecret = vi.fn().mockResolvedValue({
      _tag: "Failure",
      cause: Cause.fail({ _tag: "EnvironmentAuthorizationError", message: "forbidden" }),
    });
    await renderSection();
    await type("CLIProxyAPI management key", "sk-live");
    await act(async () => {
      byLabel("Save CLIProxyAPI and relaunch").props.onClick();
    });
    expect(rendered()).toContain("Only the desktop app on this Mac can change engine secrets.");
  });

  it("keeps Test Connection off until the Mac has the verb", async () => {
    await renderSection();
    const button = byLabel("Test CLIProxyAPI connection");
    expect(button.props.disabled).toBe(true);
    expect(rendered()).toContain("needs a newer Infinitus app");
  });

  it("probes the typed url without saving and reports the round trip", async () => {
    fake.snapshot = snapshot([...ENGINE_COMMANDS, command("test-connection")]);
    fake.run = vi.fn(async ({ input }: { input: { command: string } }) =>
      input.command === "test-connection" ? reply({ ok: true, latencyMs: 12 }) : answerReads(input),
    );
    await renderSection();
    await type("CLIProxyAPI base URL", "http://10.0.0.9:8317");
    await act(async () => {
      byLabel("Test CLIProxyAPI connection").props.onClick();
    });
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: {
        command: "test-connection",
        args: ["cliproxy"],
        options: { url: "http://10.0.0.9:8317" },
      },
    });
    expect(fake.runSecret).not.toHaveBeenCalled();
    expect(rendered()).toContain("Reachable in 12 ms.");
  });

  it("shows the engine's own words when the probe fails", async () => {
    fake.snapshot = snapshot([...ENGINE_COMMANDS, command("test-connection")]);
    fake.run = vi.fn(async ({ input }: { input: { command: string } }) =>
      input.command === "test-connection"
        ? reply({ ok: false, error: "connection refused" })
        : answerReads(input),
    );
    await renderSection();
    await act(async () => {
      byLabel("Test 9Router connection").props.onClick();
    });
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: {
        command: "test-connection",
        args: ["9router"],
        options: { url: "http://10.0.0.5:20128" },
      },
    });
    expect(rendered()).toContain("connection refused");
  });
});
