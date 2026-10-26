import type { ThreadId } from "@infinitus/contracts";
import type { InfinitusHeldThread } from "@infinitus/contracts/infinitus";

/** What the server's holds stream says about one thread: `held` for headroom
    (#741) or `paused` mid-turn (#743), or null when it says nothing yet. Absent
    is never held. An entry without `kind` is from a server before kinds joined
    the stream: held. Web and phone rows resolve status from this alike. */
export function heldEntryFor(
  holds: ReadonlyArray<InfinitusHeldThread> | null | undefined,
  threadId: ThreadId,
): { readonly kind: "held" | "paused"; readonly summary: string } | null {
  const entry = holds?.find((held) => held.threadId === threadId);
  if (entry === undefined) return null;
  return { kind: entry.kind ?? "held", summary: entry.summary };
}
