import type { ThreadPullRequestWatchEnd } from "@infinitus/contracts";
import type { InfinitusLimitStop } from "@infinitus/contracts/infinitus";
import { limitStopKey } from "@infinitus/client-runtime/state/infinitusLimitStops";
import { visibleThreadPullRequests } from "@infinitus/shared/threadPullRequests";

import type { SidebarThreadSummary } from "../../types";
import { resolveSidebarThreadStatus, type SidebarThreadStatus } from "../Sidebar.logic";

/**
 * Fork (#269 D, #270 C; re-ported onto orchestrator v2 under #1627): the
 * threads blocked on the user, across every project and environment, for the
 * section above the sidebar's list and the next-attention key. Blocked means
 * the thread waits for something only the user can give: an approval, an
 * answer, an account swap (a usage limit, #270 I / #648), or a next step
 * after the server stopped watching its pull request on its own (#269 A,
 * #1043: the pull request still needs work, and only the user can say what).
 * A failed or unread thread is not blocked and stays where it is. The
 * statuses are v2's own (`resolveSidebarThreadStatus` over the shell's
 * pending requests and run state; `watchEnded` on the link), so this file
 * adds no signal, only the cross-project view.
 */
export type NeedsAttentionStatus = "approval" | "input" | "limited" | "stopped";

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
  stopped: 3,
};

const WATCH_END_SUMMARY: Record<ThreadPullRequestWatchEnd["reason"], string> = {
  "comment-limit":
    "Stopped watching the pull request after 10 comment-only updates; it still needs work",
  unreadable: "Stopped watching the pull request: it could not be read from the host",
};

/**
 * The newest watch the server ended on its own that the user has not
 * answered with a message yet, across the thread's visible links.
 */
export function watchEndedSince(
  thread: Pick<
    SidebarThreadSummary,
    "pullRequests" | "latestUserAuthoredMessageAt" | "latestUserMessageAt"
  >,
): ThreadPullRequestWatchEnd | null {
  const lastSent = thread.latestUserAuthoredMessageAt ?? thread.latestUserMessageAt ?? null;
  let newest: ThreadPullRequestWatchEnd | null = null;
  for (const link of visibleThreadPullRequests(thread.pullRequests)) {
    const ended = link.watchEnded;
    if (ended === undefined) continue;
    if (lastSent !== null && lastSent > ended.at) continue;
    if (newest === null || ended.at > newest.at) newest = ended;
  }
  return newest;
}

/**
 * The blocked threads in the order the user should take them: approvals,
 * then questions, then limits, the longest wait first within each. A thread
 * waiting on an approval or an answer has had no change since the request
 * landed, so its `updatedAt` is when the wait began.
 */
export function collectNeedsAttention(
  threads: ReadonlyArray<SidebarThreadSummary>,
  limitStops: ReadonlyMap<string, InfinitusLimitStop>,
  describeLimitStop: (stop: InfinitusLimitStop) => string,
): ReadonlyArray<NeedsAttentionEntry> {
  const entries: NeedsAttentionEntry[] = [];
  for (const thread of threads) {
    if (thread.archivedAt !== null) continue;
    const stop = limitStops.get(limitStopKey(thread.environmentId, thread.id)) ?? null;
    const status = resolveSidebarThreadStatus(thread, { limitStopped: stop !== null });
    if (status !== "approval" && status !== "input" && status !== "limited") {
      const ended = status === "working" || status === "waiting" ? null : watchEndedSince(thread);
      if (ended !== null) {
        entries.push({
          thread,
          status: "stopped",
          since: ended.at,
          summary: WATCH_END_SUMMARY[ended.reason],
        });
      }
      continue;
    }
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
 * Where a thread sits in the "needs you next" order (#270 C): the rank the
 * keybinding minimises, or null when the thread asks nothing of the user.
 * Approval outranks input outranks a limit (the status resolver's own
 * precedence) outranks a watch the server stopped outranks a failed run; an
 * unseen completion trails them all. Working, waiting and read rows never
 * qualify.
 */
export function resolveAttentionRank(input: {
  readonly status: SidebarThreadStatus;
  readonly isUnread: boolean;
  readonly watchEnded?: boolean;
}): number | null {
  switch (input.status) {
    case "approval":
      return 0;
    case "input":
      return 1;
    case "limited":
      return 2;
    case "failed":
      return input.watchEnded ? 3 : 4;
    case "ready":
      return input.watchEnded ? 3 : input.isUnread ? 5 : null;
    default:
      return null;
  }
}

/**
 * The thread the next-attention key lands on: the lowest rank among the
 * entries, ties broken by sidebar order starting just after the current
 * thread and wrapping, so repeated presses walk every waiting thread of one
 * rank before dropping to the next. The current thread is never the answer
 * (nothing to jump to) and the order is never changed (the sort's rule).
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
