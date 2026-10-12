import type { ThreadId } from "@infinitus/contracts";
import type { InfinitusHeldThread } from "@infinitus/contracts/infinitus";

/** What the server's holds stream says about one thread, for a list row or
    a banner: `held` for headroom (#741) or `paused` for it mid-turn (#743),
    with the row's line — or null when it says nothing, or has not said yet
    (the stream is still connecting, or the server predates it). Absent is
    never held: a hold is never assumed. An entry without `kind` comes from a
    server before the kinds joined the stream: held. Web and phone rows
    resolve their status from this the same way. */
export function heldEntryFor(
  holds: ReadonlyArray<InfinitusHeldThread> | null | undefined,
  threadId: ThreadId,
): { readonly kind: "held" | "paused"; readonly summary: string } | null {
  const entry = holds?.find((held) => held.threadId === threadId);
  if (entry === undefined) return null;
  return { kind: entry.kind ?? "held", summary: entry.summary };
}
