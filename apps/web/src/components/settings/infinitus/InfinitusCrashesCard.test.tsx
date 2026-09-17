import { InfinitusCommandFailed, type InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import * as Cause from "effect/Cause";
import { act, StrictMode } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

const { fake } = vi.hoisted(() => ({
  fake: {
    snapshot: null as InfinitusSnapshot | null,
    run: vi.fn(),
    copied: [] as Array<string>,
    copyThrows: false,
  },
}));

vi.mock("./InfinitusPrefsPanel", () => ({
  useInfinitusEnvironment: () => ({
    environmentId: "env-1",
    capability: true,
    snapshot: fake.snapshot,
    serverLanOrigins: [],
  }),
}));
vi.mock("~/state/infinitus", () => ({
  infinitusEnvironment: { command: { label: "infinitus:command" } },
}));
vi.mock("~/state/use-atom-command", () => ({ useAtomCommand: () => fake.run }));
vi.mock("~/hooks/useCopyToClipboard", () => ({
  writeTextToClipboard: (text: string) => {
    if (fake.copyThrows) return Promise.reject(new Error("the clipboard said no"));
    fake.copied.push(text);
    return Promise.resolve();
  },
}));

import { InfinitusCrashesCard } from "./InfinitusCrashesCard";

const CRASHES_COMMAND = {
  name: "crashes",
  args: [],
  options: ["--id <id>"],
  effect: "read" as const,
  summary: "",
  replyShape: "",
};

function snapshot(
  commands: ReadonlyArray<typeof CRASHES_COMMAND> = [CRASHES_COMMAND],
): InfinitusSnapshot {
  return { available: true, fleets: [], commands } as unknown as InfinitusSnapshot;
}

/** A Mac before `--id`: the verb, no options. */
const OLD_CRASHES_COMMAND = { ...CRASHES_COMMAND, options: [] };

const report = {
  id: "crash-1",
  platform: "mac",
  device: "HyperNovae",
  appVersion: "0.5.0-alpha.13",
  osVersion: "macOS 26.7",
  at: "2026-09-15T12:04:00.000Z",
  kind: "crash",
  reason: "EXC_BAD_ACCESS SIGSEGV",
  frames: [],
};

const ok = (result: unknown) => ({ _tag: "Success", value: { result } });

let renderer: ReactTestRenderer | undefined;

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  fake.snapshot = snapshot();
  fake.copied = [];
  fake.copyThrows = false;
  fake.run = vi.fn().mockResolvedValue(ok({ crashes: [report] }));
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
        <InfinitusCrashesCard />
      </StrictMode>,
    );
  });
}

function rendered(): string {
  return JSON.stringify(renderer!.toJSON());
}

function copyButton() {
  return renderer!.root.findAll(
    (node) =>
      typeof node.type !== "string" &&
      typeof (node.props as { onClick?: unknown }).onClick === "function",
  )[0]!;
}

describe("InfinitusCrashesCard", () => {
  it("lists the Mac's reports without asking for any transcript", async () => {
    await renderCard();

    expect(fake.run).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { command: "crashes", args: [], options: {} },
    });
    const output = rendered();
    expect(output).toContain("HyperNovae · crash · EXC_BAD_ACCESS SIGSEGV");
    expect(output).toContain("app 0.5.0-alpha.13 · macOS 26.7");
  });

  it("says so when the Mac has recorded none", async () => {
    fake.run = vi.fn().mockResolvedValue(ok({ crashes: [] }));
    await renderCard();

    expect(rendered()).toContain("None. The phone reports its own crashes");
  });

  it("draws nothing at all on a build whose crashes verb predates --id", async () => {
    fake.snapshot = snapshot([OLD_CRASHES_COMMAND]);
    await renderCard();

    expect(renderer!.toJSON()).toBeNull();
    expect(fake.run).not.toHaveBeenCalled();
  });

  it("asks for the one report's transcript on Copy, and copies that", async () => {
    fake.run = vi
      .fn()
      .mockResolvedValueOnce(ok({ crashes: [report] }))
      .mockResolvedValueOnce(ok({ crashes: [report] }))
      .mockResolvedValue(ok({ crashes: [{ ...report, transcript: "reason: EXC_BAD_ACCESS" }] }));
    await renderCard();
    await act(async () => {
      copyButton().props.onClick();
    });

    expect(fake.run).toHaveBeenLastCalledWith({
      environmentId: "env-1",
      input: { command: "crashes", args: [], options: { id: "crash-1" } },
    });
    expect(fake.copied).toEqual(["reason: EXC_BAD_ACCESS"]);
    expect(rendered()).toContain("Copied");
  });

  it("shows the Mac's own error verbatim when the read fails", async () => {
    fake.run = vi.fn().mockResolvedValue({
      _tag: "Failure",
      cause: Cause.fail(
        new InfinitusCommandFailed({
          command: "crashes",
          error: "the app is not answering",
          restarting: false,
        }),
      ),
    });
    await renderCard();

    expect(rendered()).toContain("the app is not answering");
  });
});
