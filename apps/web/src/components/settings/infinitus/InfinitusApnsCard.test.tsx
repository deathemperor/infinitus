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
  usePrimarySettings: (selector: (settings: { timestampFormat: string }) => unknown) =>
    selector({ timestampFormat: "24-hour" }),
}));
vi.mock("../settingsLayout", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../settingsLayout")>()),
  SettingsPageContainer: ({ children }: { children: ReactNode }) => children,
}));

import { InfinitusApnsCard } from "./InfinitusApnsCard";

const command = (name: string, stdin?: string) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
  ...(stdin === undefined ? {} : { stdin }),
});

const APNS_COMMANDS = [command("apns"), command("apns-key", "secret")];

function snapshot(
  keyId: string,
  commands: ReadonlyArray<unknown> = APNS_COMMANDS,
): InfinitusSnapshot {
  return {
    available: true,
    fleets: [],
    commands,
    prefs: {
      sections: [],
      prefs: [
        {
          key: "apns_key_id",
          type: "string",
          default: "",
          value: keyId,
          section: "devices",
          effect: "live",
        },
      ],
    },
  } as unknown as InfinitusSnapshot;
}

const reply = (result: unknown) => ({ _tag: "Success", value: { result } });

const PEM = "-----BEGIN PRIVATE KEY-----\nMIGTAgEA\n-----END PRIVATE KEY-----\n";

const STORED: Record<string, unknown> = {
  keyPresent: true,
  teamId: "TEAM123456",
  keyId: "KEY1234567",
  registrations: [
    {
      deviceId: "d1",
      deviceName: "Ada's iPhone",
      kind: "alert",
      environment: "production",
      registeredAt: "2026-09-14T09:00:00Z",
    },
  ],
};

let status: Record<string, unknown> = STORED;

let renderer: ReactTestRenderer | undefined;

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  fake.capability = true;
  status = STORED;
  fake.snapshot = snapshot("KEY1234567");
  fake.run = vi.fn(async () => reply(status));
  fake.runSecret = vi.fn().mockResolvedValue(reply({ stored: true }));
});

afterEach(async () => {
  await act(() => renderer?.unmount());
  renderer = undefined;
  vi.unstubAllGlobals();
});

async function renderCard() {
  await act(async () => {
    renderer = create(
      <StrictMode>
        <InfinitusApnsCard />
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

async function pickFile(text: string) {
  const target = { files: [{ text: async () => text }], value: "C:\\fakepath\\AuthKey.p8" };
  await act(async () => {
    await byLabel("APNs key file").props.onChange({ target });
  });
  return target;
}

describe("InfinitusApnsCard", () => {
  it("reads the setup and lists the registered phones", async () => {
    await renderCard();
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "apns", args: [], options: {} },
    });
    const text = rendered();
    expect(text).toContain("In the Keychain.");
    expect(text).toContain("Ada's iPhone · alert · production");
  });

  it("says when no phone is registered and no key is stored", async () => {
    status = { keyPresent: false, teamId: "", keyId: "", registrations: [] };
    await renderCard();
    const text = rendered();
    expect(text).toContain("Not set up.");
    expect(text).toContain("No phones registered.");
  });

  it("sends a .p8 file's text as the secret, clears the input and re-reads", async () => {
    await renderCard();
    fake.run.mockClear();
    const target = await pickFile(PEM);
    expect(fake.runSecret).toHaveBeenCalledTimes(1);
    const call = fake.runSecret.mock.calls[0]![0] as {
      environmentId: string;
      input: { command: string; args: Record<string, string>; secret: Redacted.Redacted<string> };
    };
    expect(call.environmentId).toBe("env-1");
    expect(call.input.command).toBe("apns-key");
    expect(call.input.args).toEqual({});
    expect(Redacted.value(call.input.secret)).toBe(PEM);
    expect(target.value).toBe("");
    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "apns", args: [], options: {} },
    });
    expect(rendered()).not.toContain("MIGTAgEA");
  });

  it("refuses a file that is not a PEM private key without sending it", async () => {
    await renderCard();
    await pickFile("-----BEGIN CERTIFICATE-----\nabc\n");
    expect(fake.runSecret).not.toHaveBeenCalled();
    expect(rendered()).toContain("not a .p8 key");
  });

  it("forgets the key with an empty secret", async () => {
    await renderCard();
    await act(async () => {
      byLabel("Forget APNs key").props.onClick();
    });
    const call = fake.runSecret.mock.calls[0]![0] as {
      input: { command: string; secret: Redacted.Redacted<string> };
    };
    expect(call.input.command).toBe("apns-key");
    expect(Redacted.value(call.input.secret)).toBe("");
  });

  it("keeps the file input off until the key id pref is set", async () => {
    fake.snapshot = snapshot("");
    status = { keyPresent: false, teamId: "", keyId: "", registrations: [] };
    await renderCard();
    expect(byLabel("APNs key file").props.disabled).toBe(true);
    expect(rendered()).toContain("Set the Key ID above first");
  });

  it("shows the server's refusal verbatim and keeps the key out of it", async () => {
    fake.runSecret = vi.fn().mockResolvedValueOnce({
      _tag: "Failure",
      cause: Cause.fail(
        new InfinitusSecretRefused({
          command: "apns-key",
          reason: "bad_args",
          detail: "apns-key: set the key id first",
        }),
      ),
    });
    await renderCard();
    await pickFile(PEM);
    const text = rendered();
    expect(text).toContain("apns-key: set the key id first");
    expect(text).not.toContain("MIGTAgEA");
  });

  it("refuses on a build whose manifest lacks the key verb's secret marker", async () => {
    fake.snapshot = snapshot("KEY1234567", [command("apns"), command("apns-key")]);
    await renderCard();
    expect(rendered()).toContain("no push key commands");
    expect(fake.run).not.toHaveBeenCalled();
  });
});
