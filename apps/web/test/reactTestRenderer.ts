import { act as reactAct } from "react";
import { vi } from "vite-plus/test";

declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean | undefined;
}

const isPromiseLike = (value: unknown): value is PromiseLike<unknown> =>
  typeof value === "object" &&
  value !== null &&
  typeof (value as { then?: unknown }).then === "function";

/**
 * React's act() for the fork's react-test-renderer unit tests, which run outside the
 * browser runner that apps/web/test/render.tsx serves. Like that helper's act, it turns
 * IS_REACT_ACT_ENVIRONMENT on only while the callback runs (nested calls restore the outer
 * value); unlike it, a synchronous callback still flushes synchronously, so a sync mount
 * helper can return the renderer it created.
 */
export const act = actWithEnvironment as typeof reactAct;

function actWithEnvironment(callback: () => unknown): unknown {
  const previous = globalThis.IS_REACT_ACT_ENVIRONMENT;
  const restore = () => {
    globalThis.IS_REACT_ACT_ENVIRONMENT = previous;
  };
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  let returned: unknown;
  let pending: PromiseLike<unknown>;
  try {
    pending = reactAct(() => {
      returned = callback();
      return returned;
    });
  } catch (error) {
    restore();
    throw error;
  }
  if (isPromiseLike(returned)) return Promise.resolve(pending).finally(restore);
  restore();
  return pending;
}

/** Fake timers for one test: `using _timers = fakeTimers()`. */
export function fakeTimers(config?: Parameters<typeof vi.useFakeTimers>[0]): Disposable {
  vi.useFakeTimers(config);
  return { [Symbol.dispose]: () => void vi.useRealTimers() };
}
