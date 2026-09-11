// @effect-diagnostics globalTimers:off -- The fakes settle promise chains with a macrotask; no Effect fiber is involved.
import type { DesktopCaptureGestureEvent } from "@t3tools/contracts";
import { describe, expect, it, vi } from "vite-plus/test";

import { type CaptureGestureDeps, makeCaptureGesture } from "./InfinitusCaptureGesture.ts";

function harness(overrides: Partial<CaptureGestureDeps> = {}) {
  let trigger: (() => void) | undefined;
  let fail: ((error: Error) => void) | undefined;
  const stop = vi.fn();
  const dispatched: DesktopCaptureGestureEvent[] = [];
  const logged: Array<[string, Record<string, string | number> | undefined]> = [];
  let read: () => Promise<DesktopCaptureGestureEvent> = async () => ({
    type: "captured",
    text: "hello",
  });
  const deps: CaptureGestureDeps = {
    startPoller: vi.fn(async (onTrigger, onFailure) => {
      trigger = onTrigger;
      fail = onFailure;
      return stop;
    }),
    readSelectedText: () => read(),
    dispatch: async (event) => {
      dispatched.push(event);
    },
    accessibilityGranted: vi.fn(() => true),
    confirm: vi.fn(),
    log: (message, data) => {
      logged.push([message, data]);
    },
    ...overrides,
  };
  const gesture = makeCaptureGesture(deps);
  const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
  return {
    gesture,
    deps,
    stop,
    dispatched,
    logged,
    settle,
    trigger: () => trigger?.(),
    fail: (error: Error) => fail?.(error),
    setRead: (next: typeof read) => {
      read = next;
    },
  };
}

describe("makeCaptureGesture", () => {
  it("starts the poller on enable, once, and stops it on disable", async () => {
    const h = harness();
    await h.gesture.setEnabled(true, { prompt: true });
    await h.gesture.setEnabled(true);
    expect(h.deps.startPoller).toHaveBeenCalledOnce();
    expect(h.deps.accessibilityGranted).toHaveBeenCalledWith(true);
    await h.gesture.setEnabled(false);
    expect(h.stop).toHaveBeenCalledOnce();
    await h.gesture.setEnabled(true);
    expect(h.deps.startPoller).toHaveBeenCalledTimes(2);
  });

  it("dispatches the read, confirms only text, and logs the length not the text", async () => {
    const h = harness();
    await h.gesture.setEnabled(true);
    h.trigger();
    await h.settle();
    expect(h.dispatched).toEqual([{ type: "captured", text: "hello" }]);
    expect(h.deps.confirm).toHaveBeenCalledOnce();
    expect(h.logged).toContainEqual(["gesture", { outcome: "captured", length: 5 }]);
    expect(JSON.stringify(h.logged)).not.toContain("hello");

    h.setRead(async () => ({ type: "empty" }));
    h.trigger();
    await h.settle();
    h.setRead(async () => ({ type: "failed", reason: "accessibility" }));
    h.trigger();
    await h.settle();
    expect(h.dispatched.slice(1)).toEqual([
      { type: "empty" },
      { type: "failed", reason: "accessibility" },
    ]);
    expect(h.deps.confirm).toHaveBeenCalledOnce();
    expect(h.logged).toContainEqual(["gesture", { outcome: "failed", reason: "accessibility" }]);
  });

  it("runs one read at a time and reports a reader that throws as the helper failing", async () => {
    const h = harness();
    let release: (() => void) | undefined;
    h.setRead(
      () =>
        new Promise((resolve) => {
          release = () => resolve({ type: "captured", text: "slow" });
        }),
    );
    await h.gesture.setEnabled(true);
    h.trigger();
    h.trigger();
    release?.();
    await h.settle();
    expect(h.dispatched).toEqual([{ type: "captured", text: "slow" }]);

    h.setRead(async () => {
      throw new Error("boom");
    });
    h.trigger();
    await h.settle();
    expect(h.dispatched.at(-1)).toEqual({ type: "failed", reason: "helper" });
  });

  it("logs a poller that dies and starts a fresh one on the next enable", async () => {
    const h = harness();
    await h.gesture.setEnabled(true);
    h.fail(new Error("helper exited with code 1"));
    expect(h.logged).toContainEqual(["poller failed", { error: "helper exited with code 1" }]);
    await h.gesture.setEnabled(true);
    expect(h.deps.startPoller).toHaveBeenCalledTimes(2);
  });

  it("stops a poller that came up after the knob went off again", async () => {
    let resolveStart: ((stop: () => void) => void) | undefined;
    const stop = vi.fn();
    const h = harness({
      startPoller: vi.fn(
        () =>
          new Promise<() => void>((resolve) => {
            resolveStart = resolve;
          }),
      ),
    });
    const enabling = h.gesture.setEnabled(true);
    await h.gesture.setEnabled(false);
    resolveStart?.(stop);
    await enabling;
    expect(stop).toHaveBeenCalledOnce();
  });

  it("still starts without the grant, so the read can say what is missing", async () => {
    const h = harness({ accessibilityGranted: vi.fn(() => false) });
    await h.gesture.setEnabled(true, { prompt: true });
    expect(h.deps.startPoller).toHaveBeenCalledOnce();
    expect(h.logged).toContainEqual(["accessibility not granted", undefined]);
  });
});
