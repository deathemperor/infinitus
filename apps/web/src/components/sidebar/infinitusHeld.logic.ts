import type { ThreadId } from "@t3tools/contracts";
import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";

/** The held row's line for this thread, or null when the server does not
    hold it — or has not said yet (the stream is still connecting, or the
    server predates it). Absent is never held: a hold is never assumed. */
export function heldSummaryFor(
  holds: ReadonlyArray<InfinitusHeldThread> | null | undefined,
  threadId: ThreadId,
): string | null {
  return holds?.find((held) => held.threadId === threadId)?.summary ?? null;
}
