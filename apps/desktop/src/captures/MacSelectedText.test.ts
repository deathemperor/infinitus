import { afterEach, describe, expect, it, vi } from "vite-plus/test";

const { spawned } = vi.hoisted(() => ({
  spawned: [] as Array<{
    args: ReadonlyArray<string>;
    kill: ReturnType<typeof vi.fn>;
    emitStdout: (text: string) => void;
    emitClose: (code: number) => void;
    emitError: () => void;
  }>,
}));

vi.mock("node:child_process", () => ({
  spawn: (_command: string, args: ReadonlyArray<string>) => {
    const stdoutListeners: Array<(chunk: Buffer) => void> = [];
    const onceListeners = new Map<string, Array<(value?: unknown) => void>>();
    const fire = (event: string, value?: unknown) => {
      for (const listener of onceListeners.get(event) ?? []) listener(value);
    };
    const record = {
      args,
      kill: vi.fn(() => true),
      emitStdout: (text: string) => {
        for (const listener of stdoutListeners) listener(Buffer.from(text));
      },
      emitClose: (code: number) => fire("close", code),
      emitError: () => fire("error", new Error("spawn failed")),
    };
    spawned.push(record);
    const child = {
      stdout: {
        on: (_event: "data", listener: (chunk: Buffer) => void) => {
          stdoutListeners.push(listener);
          return child;
        },
      },
      once: (event: string, listener: (value?: unknown) => void) => {
        onceListeners.set(event, [...(onceListeners.get(event) ?? []), listener]);
        return child;
      },
      kill: record.kill,
    };
    return child;
  },
}));

import { parseSelectedTextOutput, readMacSelectedText } from "./MacSelectedText.ts";

afterEach(() => {
  vi.useRealTimers();
  spawned.length = 0;
});

describe("parseSelectedTextOutput", () => {
  it("turns the helper's line into the event", () => {
    expect(parseSelectedTextOutput('{"ok":true,"text":"a line"}\n')).toEqual({
      type: "captured",
      text: "a line",
    });
    expect(parseSelectedTextOutput('{"ok":true,"text":"  \\n"}')).toEqual({ type: "empty" });
    expect(parseSelectedTextOutput('{"ok":false,"reason":"accessibility"}')).toEqual({
      type: "failed",
      reason: "accessibility",
    });
    expect(parseSelectedTextOutput('{"ok":false,"reason":"no-focus"}')).toEqual({
      type: "failed",
      reason: "no-focus",
    });
    expect(parseSelectedTextOutput('{"ok":false,"reason":"unsupported"}')).toEqual({
      type: "failed",
      reason: "unsupported",
    });
  });

  it("treats anything else as the helper failing", () => {
    expect(parseSelectedTextOutput("")).toEqual({ type: "failed", reason: "helper" });
    expect(parseSelectedTextOutput("not json")).toEqual({ type: "failed", reason: "helper" });
    expect(parseSelectedTextOutput('{"ok":false,"reason":"other"}')).toEqual({
      type: "failed",
      reason: "helper",
    });
    expect(parseSelectedTextOutput('{"ok":true}')).toEqual({ type: "failed", reason: "helper" });
  });
});

describe("readMacSelectedText", () => {
  it("passes the capture cap and resolves with the helper's line", async () => {
    const read = readMacSelectedText();
    const child = spawned[0]!;
    expect(child.args.at(-1)).toBe("8192");
    child.emitStdout('{"ok":true,"te');
    child.emitStdout('xt":"hello"}\n');
    child.emitClose(0);
    await expect(read).resolves.toEqual({ type: "captured", text: "hello" });
  });

  it("fails on a non-zero exit or a spawn error", async () => {
    const exited = readMacSelectedText();
    spawned[0]!.emitStdout('{"ok":true,"text":"x"}');
    spawned[0]!.emitClose(1);
    await expect(exited).resolves.toEqual({ type: "failed", reason: "helper" });

    const errored = readMacSelectedText();
    spawned[1]!.emitError();
    await expect(errored).resolves.toEqual({ type: "failed", reason: "helper" });
  });

  it("kills a helper that does not answer in time", async () => {
    vi.useFakeTimers();
    const read = readMacSelectedText();
    vi.advanceTimersByTime(3_000);
    await expect(read).resolves.toEqual({ type: "failed", reason: "timeout" });
    expect(spawned[0]!.kill).toHaveBeenCalledOnce();
    // The late close changes nothing.
    spawned[0]!.emitClose(0);
  });
});
