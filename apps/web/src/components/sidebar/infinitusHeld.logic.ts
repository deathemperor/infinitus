import type { ThreadId } from "@t3tools/contracts";
import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";

/** What the server says about this thread: `held` for headroom (#741) or
    `limited`, parked on a usage limit (#270 I), with the row's line — or
    null when it says nothing, or has not said yet (the stream is still
    connecting, or the server predates it). Absent is never held: a hold is
    never assumed. An entry without `kind` comes from a server before
    limits joined the stream: held. */
export function heldEntryFor(
  holds: ReadonlyArray<InfinitusHeldThread> | null | undefined,
  threadId: ThreadId,
): { readonly kind: "held" | "limited"; readonly summary: string } | null {
  const entry = holds?.find((held) => held.threadId === threadId);
  if (entry === undefined) return null;
  return { kind: entry.kind ?? "held", summary: entry.summary };
}
