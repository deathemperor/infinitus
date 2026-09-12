import { turnFooter, type TurnFooter } from "@t3tools/client-runtime/turnFooter";
import type { OrchestrationThread, TurnId } from "@t3tools/contracts";
import { useMemo } from "react";

export type TurnFooters = ReadonlyMap<TurnId, TurnFooter>;

/**
 * Fork (#952): the footers of a thread's completed turns, keyed by turn —
 * the web's `useTurnFooters`, kept local so neither app edits the other's
 * file. A turn mid-flight changes the thread's activities every tick, so the
 * map is rebuilt only when its entries change (they travel through one
 * string key) and the feed rows that read it do not repaint meanwhile.
 */
export function useTurnFooters(
  thread: Pick<OrchestrationThread, "messages" | "activities" | "latestTurn" | "session"> | null,
): TurnFooters {
  const key = useMemo(() => {
    const entries: Array<[TurnId, TurnFooter]> = [];
    if (thread !== null) {
      const seen = new Set<TurnId>();
      for (const message of thread.messages) {
        if (message.role !== "assistant" || message.turnId === null || seen.has(message.turnId)) {
          continue;
        }
        seen.add(message.turnId);
        const footer = turnFooter(thread, message.turnId);
        if (footer !== null) entries.push([message.turnId, footer]);
      }
    }
    return JSON.stringify(entries);
  }, [thread]);
  return useMemo(() => new Map(JSON.parse(key) as Array<[TurnId, TurnFooter]>), [key]);
}
