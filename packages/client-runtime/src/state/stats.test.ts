import { it, expect } from "vite-plus/test";
import { Atom, AtomRegistry, AsyncResult } from "effect/unstable/reactivity";
import {
  EnvironmentId,
  UsageDay,
  type StatsSnapshot,
  type ServerConfig,
} from "@infinitus/contracts";
import { statsWindow } from "@infinitus/shared/stats";
import type { EnvironmentPresentation } from "../connection/presentation.ts";
import { createStatsAtoms } from "./stats.ts";
import type { createServerEnvironmentAtoms } from "./server.ts";

const request = { period: "week" as const, today: UsageDay.make("2026-09-22"), timeZone: "UTC" };
const snapshot: StatsSnapshot = {
  contractVersion: 1,
  readAt: "2026-09-22T10:00:00Z",
  ...statsWindow(request),
  timeZone: "UTC",
  historyFrom: "2024-01-01",
  activeDays: [],
  sessions: [],
  repositories: [],
  sources: [],
  unavailable: [],
  pricing: { status: "fresh", source: "test", knownModels: 1, fetchedAt: null },
};
function presentation(id: string, stats: boolean, phase: "connected" | "offline" = "connected") {
  return {
    entry: { target: { label: id } },
    connection: { phase, error: null, traceId: null },
    serverConfig: { environment: { capabilities: { stats } } } as ServerConfig,
  } as EnvironmentPresentation;
}
it("queries only selected connected capable servers and follows reconnects", () => {
  const mac = EnvironmentId.make("mac"),
    linux = EnvironmentId.make("linux"),
    old = EnvironmentId.make("old");
  const entries = new Map([
    [mac, presentation("mac", true)],
    [linux, presentation("linux", true, "offline")],
    [old, presentation("old", false)],
  ]);
  const presentationsAtom = Atom.make<ReadonlyMap<EnvironmentId, EnvironmentPresentation>>(entries);
  const calls: EnvironmentId[] = [];
  const query = Atom.make(AsyncResult.success(snapshot));
  const stats = ((input: { environmentId: EnvironmentId }) => {
    calls.push(input.environmentId);
    return query;
  }) as ReturnType<typeof createServerEnvironmentAtoms>["stats"];
  const atoms = createStatsAtoms({ server: { stats }, presentations: { presentationsAtom } });
  const registry = AtomRegistry.make();
  try {
    const all = atoms(JSON.stringify({ request, selectedIds: null }));
    const unmount = registry.mount(all);
    expect(registry.get(all).map((e) => e.status)).toEqual(["ready", "offline", "unsupported"]);
    expect(calls).toEqual([mac]);
    registry.set(presentationsAtom, new Map([...entries, [linux, presentation("linux", true)]]));
    expect(registry.get(all).map((e) => e.status)).toEqual(["ready", "ready", "unsupported"]);
    unmount();
    calls.length = 0;
    const selected = atoms(JSON.stringify({ request, selectedIds: [linux] }));
    expect(
      registry
        .get(selected)
        .filter((e) => e.snapshot !== null)
        .map((e) => e.environmentId),
    ).toEqual([linux]);
    expect(calls).toEqual([linux]);
  } finally {
    registry.dispose();
  }
});
