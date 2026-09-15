import { type TurnFooter, turnFooters } from "@t3tools/client-runtime/turnFooter";
import type { OrchestrationThread, TurnId } from "@t3tools/contracts";
import { useMemo } from "react";

export type TurnFooters = ReadonlyMap<TurnId, TurnFooter>;

/**
 * Fork (#952): the footers of a thread's completed turns, keyed by turn —
 * the web's `useTurnFooters`, kept local so neither app edits the other's
 * file. A turn mid-flight changes the thread's activities every tick, so the
 * map is rebuilt only when its entries change (they travel through one
 * string key) and the feed rows that read it do not repaint meanwhile; the
 * fold itself is one pass over the thread (`turnFooters`), not one per turn.
 */
export function useTurnFooters(
  thread: Pick<OrchestrationThread, "messages" | "activities" | "latestTurn" | "session"> | null,
): TurnFooters {
  const key = useMemo(
    () => (thread === null ? "[]" : JSON.stringify([...turnFooters(thread)])),
    [thread],
  );
  return useMemo(() => new Map(JSON.parse(key) as Array<[TurnId, TurnFooter]>), [key]);
}
