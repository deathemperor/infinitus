import type { OrchestrationThread, TurnId } from "@t3tools/contracts";
import { turnFooter, type TurnFooter } from "@t3tools/client-runtime/turnFooter";
import { useMemo } from "react";

export type TurnFooters = ReadonlyMap<TurnId, TurnFooter>;

/**
 * The footers of a thread's completed turns (#952), keyed by turn. A turn
 * mid-flight changes the thread's activities every tick, so the map is
 * rebuilt only when its entries change (they travel through one string
 * key) and the timeline rows that read it do not repaint meanwhile.
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
