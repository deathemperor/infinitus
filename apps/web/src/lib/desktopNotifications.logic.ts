import type { DesktopNotificationRequest, OrchestrationLatestTurn } from "@t3tools/contracts";

import type { SidebarThreadStatus } from "../components/Sidebar.logic";
import type { SeenTurn } from "./infinitusCompletionSound.logic";

/**
 * The desktop notifications' pure half (#270 B): which thread changes earn
 * an OS notification, and how many threads the Dock badge counts. A line is
 * posted when a thread this window already knew moves into approval, input,
 * held or failed, or (off by default) reaches a completed turn it had not
 * seen completed — the completion-sound rule. The thread on screen while
 * the window is focused stays quiet: the user is looking at it.
 */
export interface DesktopNotificationPrefs {
  readonly approval: boolean;
  readonly input: boolean;
  readonly held: boolean;
  readonly failure: boolean;
  readonly completion: boolean;
}

export interface WatchedThread {
  readonly environmentId: string;
  readonly id: string;
  readonly title: string;
  readonly projectTitle?: string | undefined;
  readonly status: SidebarThreadStatus;
  readonly latestTurn: {
    readonly turnId: string;
    readonly state: OrchestrationLatestTurn["state"];
  } | null;
}

/** What a thread looked like last render. */
export interface SeenThread {
  readonly status: SidebarThreadStatus;
  readonly turn: SeenTurn | null;
}

const STATUS_LINES: Partial<
  Record<SidebarThreadStatus, readonly [keyof DesktopNotificationPrefs, string]>
> = {
  approval: ["approval", "Waiting for your approval"],
  input: ["input", "Waiting for your input"],
  held: ["held", "Held for headroom"],
  failed: ["failure", "The session failed"],
};

const COMPLETION_LINE = "Finished its turn";

export function threadNotifications(
  previous: ReadonlyMap<string, SeenThread>,
  threads: ReadonlyArray<WatchedThread>,
  prefs: DesktopNotificationPrefs,
  options: { readonly viewedKey: string | null },
): {
  readonly requests: ReadonlyArray<DesktopNotificationRequest>;
  readonly next: ReadonlyMap<string, SeenThread>;
} {
  const next = new Map<string, SeenThread>();
  const requests: DesktopNotificationRequest[] = [];
  for (const thread of threads) {
    const key = `${thread.environmentId}:${thread.id}`;
    const turn: SeenTurn | null =
      thread.latestTurn === null ? null : `${thread.latestTurn.turnId}:${thread.latestTurn.state}`;
    next.set(key, { status: thread.status, turn });
    const before = previous.get(key);
    if (before === undefined || key === options.viewedKey) continue;
    const body = lineFor(before, thread, turn, prefs);
    if (body === null) continue;
    requests.push({
      environmentId: thread.environmentId as DesktopNotificationRequest["environmentId"],
      threadId: thread.id as DesktopNotificationRequest["threadId"],
      title: thread.projectTitle ? `${thread.projectTitle} · ${thread.title}` : thread.title,
      body,
    });
  }
  return { requests, next };
}

/** The status line when the status changed into one that earns a line, else
    the completion line for a turn not seen completed before; one at most. */
function lineFor(
  before: SeenThread,
  thread: WatchedThread,
  turn: SeenTurn | null,
  prefs: DesktopNotificationPrefs,
): string | null {
  const status = STATUS_LINES[thread.status];
  if (status !== undefined) {
    return before.status !== thread.status && prefs[status[0]] ? status[1] : null;
  }
  const completed = thread.latestTurn?.state === "completed" && before.turn !== turn;
  return completed && prefs.completion ? COMPLETION_LINE : null;
}

/** The threads waiting on the user: an approval to give or a question to answer. */
export function attentionCount(threads: ReadonlyArray<Pick<WatchedThread, "status">>): number {
  let count = 0;
  for (const thread of threads) {
    if (thread.status === "approval" || thread.status === "input") count += 1;
  }
  return count;
}
