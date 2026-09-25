import type { EnvironmentId, StatsRequest, StatsSnapshot } from "@infinitus/contracts";
import * as Option from "effect/Option";
import { AsyncResult, Atom } from "effect/unstable/reactivity";
import type { createEnvironmentPresentationAtoms } from "./presentation.ts";
import type { createServerEnvironmentAtoms } from "./server.ts";

export interface StatsEnvironmentStatus {
  readonly environmentId: EnvironmentId;
  readonly label: string;
  readonly selected: boolean;
  readonly status: "ready" | "scanning" | "offline" | "unsupported" | "error" | "unselected";
  readonly snapshot: StatsSnapshot | null;
}

/** Only selected, connected environments hold a query and its refresh timer. */
export function createStatsAtoms(input: {
  server: Pick<ReturnType<typeof createServerEnvironmentAtoms>, "stats">;
  presentations: Pick<ReturnType<typeof createEnvironmentPresentationAtoms>, "presentationsAtom">;
}) {
  return Atom.family((key: string) =>
    Atom.make((get): readonly StatsEnvironmentStatus[] => {
      const { request, selectedIds } = JSON.parse(key) as {
        request: StatsRequest;
        selectedIds: EnvironmentId[] | null;
      };
      const presentations = get(input.presentations.presentationsAtom);
      return [...presentations].map(([environmentId, presentation]) => {
        const selected = selectedIds === null || selectedIds.includes(environmentId);
        const base = {
          environmentId,
          label: presentation.entry.target.label,
          selected,
          snapshot: null,
        };
        if (!selected) return { ...base, status: "unselected" };
        if (presentation.connection.phase !== "connected") return { ...base, status: "offline" };
        if (presentation.serverConfig === null) return { ...base, status: "scanning" };
        if (presentation.serverConfig.environment.capabilities.stats !== true)
          return { ...base, status: "unsupported" };
        const result = get(input.server.stats({ environmentId, input: request }));
        const snapshot = Option.getOrNull(AsyncResult.value(result));
        if (snapshot !== null && snapshot.contractVersion !== 1)
          return { ...base, status: "unsupported" };
        return {
          ...base,
          snapshot,
          status:
            result._tag === "Failure"
              ? "error"
              : result.waiting || snapshot === null
                ? "scanning"
                : "ready",
        };
      });
    }).pipe(Atom.withLabel(`stats:${key}`)),
  );
}
