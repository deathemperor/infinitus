import { EnvironmentId, ThreadId } from "@infinitus/contracts";
import type { InfinitusLimitStop } from "@infinitus/contracts/infinitus";
import { AsyncResult, Atom, AtomRegistry } from "effect/reactivity";
import { describe, expect, it } from "vite-plus/test";

import type { EnvironmentCatalogState } from "./connections.ts";
import { createInfinitusLimitStopsAtom, limitStopKey, limitStopLine } from "./infinitusLimitStops.ts";

const mac = EnvironmentId.make("mac");
const linux = EnvironmentId.make("linux");
const stop = (threadId: string, overrides: Partial<InfinitusLimitStop> = {}): InfinitusLimitStop => ({
  threadId: ThreadId.make(threadId),
  kind: "parked",
  since: "2026-10-11T02:22:49.000Z",
  account: "hiep1",
  resetsAt: "2026-10-15T08:00:00.000Z",
  ...overrides,
});

describe("limitStopLine", () => {
  const formatTime = (iso: string) => `at ${iso}`;
  const before = Date.parse("2026-10-11T03:00:00Z");

  it("names the account and the reset while it is still ahead", () => {
    expect(limitStopLine(stop("t"), formatTime, before)).toBe(
      "Limit hit on hiep1 · resets at 2026-10-15T08:00:00.000Z",
    );
    expect(limitStopLine(stop("t"), formatTime, Date.parse("2026-10-16T00:00:00Z"))).toBe(
      "Limit hit on hiep1",
    );
    expect(limitStopLine(stop("t", { resetsAt: null }), formatTime, before)).toBe("Limit hit on hiep1");
  });

  it("names the proxy, or nobody", () => {
    expect(limitStopLine(stop("t", { proxy: "cliproxy", resetsAt: null }), formatTime, before)).toBe(
      "Limit hit on the proxy instance cliproxy",
    );
    expect(limitStopLine(stop("t", { account: null, resetsAt: "not a date" }), formatTime, before)).toBe(
      "Limit hit",
    );
  });
});

describe("createInfinitusLimitStopsAtom", () => {
  const catalog = (
    entries: ReadonlyArray<[EnvironmentId, boolean]>,
  ): EnvironmentCatalogState =>
    ({
      entries: new Map(entries.map(([id, enabled]) => [id, { enabled }])),
    }) as never;

  it("folds every enabled environment's stops into one map, replaced only on change", () => {
    const catalogAtom = Atom.make(catalog([[mac, true], [linux, false]]));
    const stopsAtom = (stops: ReadonlyArray<InfinitusLimitStop>) =>
      Atom.make<AsyncResult.AsyncResult<ReadonlyArray<InfinitusLimitStop>, unknown>>(AsyncResult.success(stops));
    const results = new Map([
      [mac, stopsAtom([stop("a"), stop("b")])],
      [linux, stopsAtom([stop("c")])],
    ]);
    const combined = createInfinitusLimitStopsAtom({
      catalogValueAtom: catalogAtom,
      limitStopsAtom: ({ environmentId }) => results.get(environmentId)!,
    });
    const registry = AtomRegistry.make();
    const first = registry.get(combined);
    expect([...first.keys()]).toEqual([limitStopKey(mac, ThreadId.make("a")), limitStopKey(mac, ThreadId.make("b"))]);
    // The same stops again: the same map, so rows do not re-render.
    registry.set(results.get(mac)!, AsyncResult.success([stop("a"), stop("b")]));
    expect(registry.get(combined)).toBe(first);
    // A stop leaving replaces it; a loading or failed stream contributes nothing.
    registry.set(results.get(mac)!, AsyncResult.success([stop("a")]));
    expect([...registry.get(combined).keys()]).toEqual([limitStopKey(mac, ThreadId.make("a"))]);
    registry.set(results.get(mac)!, AsyncResult.initial(true));
    expect(registry.get(combined).size).toBe(0);
  });
});
