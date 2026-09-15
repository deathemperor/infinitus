import type { OrchestrationThread, TurnId } from "@t3tools/contracts";
import { turnFooters, type TurnFooter } from "@t3tools/client-runtime/turnFooter";
import { useMemo } from "react";

export type TurnFooters = ReadonlyMap<TurnId, TurnFooter>;

/**
 * The footers of a thread's completed turns (#952), keyed by turn — one
 * pass over the thread (`turnFooters`, #1279) instead of one per turn. A
 * turn mid-flight changes the thread's activities every tick, so the map is
 * rebuilt only when its entries change (they travel through one string
 * key) and the timeline rows that read it do not repaint meanwhile.
 */
export function useTurnFooters(
  thread: Pick<OrchestrationThread, "messages" | "activities" | "latestTurn" | "session"> | null,
): TurnFooters {
  const key = useMemo(
    () => JSON.stringify(thread === null ? [] : [...turnFooters(thread)]),
    [thread],
  );
  return useMemo(() => new Map(JSON.parse(key) as Array<[TurnId, TurnFooter]>), [key]);
}
