import type { InfinitusLimitStop } from "@infinitus/contracts/infinitus";
import { limitStopKey } from "@infinitus/client-runtime/state/infinitusLimitStops";

import type { SidebarThreadSummary } from "../../types";
import {
  filterSidebarV2VisibleThreads,
  resolveSidebarThreadStatus,
  type SidebarThreadStatus,
} from "../Sidebar.logic";

/**
 * Fork (#269 D, #270 C, #1627): the threads blocked on the user across every project and
 * environment: an approval, an answer, or an account swap (usage limit, #270 I / #648). A failed or
 * unread thread is not blocked. Statuses are v2's own (`resolveSidebarThreadStatus`); this file
 * adds only the cross-project view.
 */
export type NeedsAttentionStatus = "approval" | "input" | "limited";

export interface NeedsAttentionEntry {
  readonly thread: SidebarThreadSummary;
  readonly status: NeedsAttentionStatus;
  /** When the wait began: the limit stop's own timestamp, else the thread's last change. */
  readonly since: string;
  /** The limit stop's line (which account, when it resets), when there is one. */
  readonly summary: string | null;
}

const STATUS_ORDER: Record<NeedsAttentionStatus, number> = {
  approval: 0,
  input: 1,
  limited: 2,
};

/**
 * The blocked threads in the order the user should take them: approvals, then questions, then
 * limits, longest wait first within each (`updatedAt` is when the wait began). Takes every shell:
 * the section ignores the sidebar's project scope and skips archived threads and subagents itself.
 */
export function collectNeedsAttention(
  threads: ReadonlyArray<SidebarThreadSummary>,
  limitStops: ReadonlyMap<string, InfinitusLimitStop>,
  describeLimitStop: (stop: InfinitusLimitStop) => string,
): ReadonlyArray<NeedsAttentionEntry> {
  const entries: NeedsAttentionEntry[] = [];
  for (const thread of filterSidebarV2VisibleThreads(threads, null)) {
    const stop = limitStops.get(limitStopKey(thread.environmentId, thread.id)) ?? null;
    const status = resolveSidebarThreadStatus(thread, { limitStopped: stop !== null });
    if (status !== "approval" && status !== "input" && status !== "limited") continue;
    entries.push({
      thread,
      status,
      since: stop?.since ?? thread.updatedAt,
      summary: stop === null ? null : describeLimitStop(stop),
    });
  }
  return entries.sort(
    (left, right) =>
      STATUS_ORDER[left.status] - STATUS_ORDER[right.status] ||
      (left.since < right.since ? -1 : left.since > right.since ? 1 : 0),
  );
}

/**
 * Where a thread sits in the "needs you next" order (#270 C): the rank the keybinding minimises, or
 * null when the thread asks nothing of the user. Approval outranks input outranks a limit outranks
 * a failed run (the status resolver's precedence); an unseen completion trails them all.
 */
export function resolveAttentionRank(input: {
  readonly status: SidebarThreadStatus;
  readonly isUnread: boolean;
}): number | null {
  switch (input.status) {
    case "approval":
      return 0;
    case "input":
      return 1;
    case "limited":
      return 2;
    case "failed":
      return 3;
    case "ready":
      return input.isUnread ? 4 : null;
    default:
      return null;
  }
}

/**
 * The thread the next-attention key lands on: the lowest rank, ties broken by sidebar order
 * starting just after the current thread and wrapping. The current thread is never the answer and
 * the order is never changed.
 */
export function resolveNextAttentionThreadId<T>(input: {
  readonly entries: ReadonlyArray<{ readonly id: T; readonly rank: number | null }>;
  readonly currentThreadId: T | null;
}): T | null {
  const { currentThreadId, entries } = input;
  const currentIndex =
    currentThreadId === null ? -1 : entries.findIndex((entry) => entry.id === currentThreadId);
  let best: { id: T; rank: number } | null = null;
  for (let step = 1; step <= entries.length; step += 1) {
    const entry = entries[(currentIndex + step) % entries.length];
    if (entry === undefined || entry.rank === null || entry.id === currentThreadId) continue;
    if (best === null || entry.rank < best.rank) best = { id: entry.id, rank: entry.rank };
    if (best.rank === 0) break;
  }
  return best?.id ?? null;
}
