import { sessionRows } from "@t3tools/client-runtime/state/infinitusSessions";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/** The sessions needing a person (waiting, or a sign-in pending), for the home
    chip's badge. The phone's Sessions card itself is gone (#941: threads are
    the phone's whole surface); the desktop sidebar keeps the rows. */
export function attentionSessionCount(snapshot: InfinitusSnapshot | null): number {
  if (snapshot === null || !snapshot.available) return 0;
  return sessionRows(snapshot, 0).filter((row) => row.needsAttention).length;
}
