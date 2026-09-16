import { BABYSIT_MAX_ROUNDS, type EnvironmentId } from "@infinitus/contracts";
import type { InfinitusHeldThread } from "@infinitus/contracts/infinitus";

import type { SidebarThreadSummary } from "../../types";
import { resolveSidebarThreadStatus } from "../Sidebar.logic";

/**
 * Fork (#269 D): the threads blocked on the user, across every project and
 * environment, for the section above the sidebar's list. Blocked means the
 * thread waits for something only the user can give: an approval, an
 * answer, headroom (a held start, #741), or an account swap (a usage limit,
 * #270 I), or a next step after babysit stopped at its round cap (#269 A:
 * the pull request still needs work, and only the user can say what). A
 * failed or unread thread is not blocked and stays where it is.
 */
export type NeedsAttentionStatus = "approval" | "input" | "held" | "limited" | "stopped";

export interface NeedsAttentionEntry {
  readonly thread: SidebarThreadSummary;
  readonly status: NeedsAttentionStatus;
  /** When the wait began: the hold's own timestamp, else the thread's last change. */
  readonly since: string;
  /** The hold's line (which account, what it waits for), when there is one. */
  readonly summary: string | null;
}

const STATUS_ORDER: Record<NeedsAttentionStatus, number> = {
  approval: 0,
  input: 1,
  held: 2,
  limited: 3,
  stopped: 4,
};

/** A babysit stopped at the cap that the user has not answered with a message yet. */
function babysitStoppedAt(thread: SidebarThreadSummary): string | null {
  const stoppedAt = thread.babysit?.stoppedAt;
  if (stoppedAt === undefined) return null;
  return thread.latestUserMessageAt !== null && thread.latestUserMessageAt > stoppedAt
    ? null
    : stoppedAt;
}

/**
 * The blocked threads in the order the user should take them: approvals,
 * then questions, then holds, then limits, the longest wait first within
 * each. A thread waiting on an approval or an answer has had no change since
 * the request landed, so its `updatedAt` is when the wait began.
 */
export function collectNeedsAttention(
  threads: ReadonlyArray<SidebarThreadSummary>,
  holdsByEnvironment: ReadonlyMap<EnvironmentId, ReadonlyArray<InfinitusHeldThread> | null>,
): ReadonlyArray<NeedsAttentionEntry> {
  const entries: NeedsAttentionEntry[] = [];
  for (const thread of threads) {
    const hold = holdsByEnvironment
      .get(thread.environmentId)
      ?.find((held) => held.threadId === thread.id);
    const holdKind = hold === undefined ? null : (hold.kind ?? "held");
    const status = resolveSidebarThreadStatus(thread, {
      held: holdKind === "held",
      limited: holdKind === "limited",
    });
    if (status !== "approval" && status !== "input" && status !== "held" && status !== "limited") {
      const stoppedAt = babysitStoppedAt(thread);
      if (stoppedAt !== null) {
        entries.push({
          thread,
          status: "stopped",
          since: stoppedAt,
          summary: `Babysit stopped after ${BABYSIT_MAX_ROUNDS} rounds; the pull request still needs work`,
        });
      }
      continue;
    }
    entries.push({
      thread,
      status,
      since: hold?.since ?? thread.updatedAt,
      summary: hold?.summary ?? null,
    });
  }
  return entries.sort(
    (left, right) =>
      STATUS_ORDER[left.status] - STATUS_ORDER[right.status] ||
      (left.since < right.since ? -1 : left.since > right.since ? 1 : 0),
  );
}
