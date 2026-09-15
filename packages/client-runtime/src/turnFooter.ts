import {
  classifyTaskAgentKind,
  type OrchestrationMessage,
  type OrchestrationThread,
  type OrchestrationThreadActivity,
  type TurnId,
} from "@t3tools/contracts";
import { formatDuration } from "@t3tools/shared/orchestrationTiming";

/**
 * The turn footer (#952): "Done in 49s · 12:59 PM · 1 shell still running"
 * under a completed turn's last assistant message, derived from what the
 * thread already carries — no contract of its own. Web and phone share this;
 * the caller formats the time in the user's timestamp format.
 *
 * Duration is the turn's timing on the client, not the server's recorded
 * `durationMs` (the per-turn usage row never reaches the client; only the
 * summed rollup does): the latest turn's `startedAt → completedAt`, an older
 * turn's user message `createdAt` → its last assistant `updatedAt`, which is
 * what the on-screen message durations use, so the two agree. An older
 * turn's number overstates by any hold or queue wait before it started.
 *
 * Shells: a Claude background Bash task of the turn (`task.started` with a
 * bash/shell `taskType`, backgrounded on that row or by a later
 * `task.updated {isBackgrounded: true}`) counts until its end — `endedAt`, a
 * terminal status, or `task.completed` — which lands after the turn under
 * the next turn's id or none, so ends are looked up across the whole thread
 * by task id. Agents (#974) are the same rule for the turn's subagent tasks
 * (`agentKind: "agent"` as ingestion stamps it, else classified from the
 * task type): a foreground agent finished inside the turn, so only a
 * backgrounded one can still be running. A session that stopped or failed
 * took its shells and agents with it. Codex has no background tasks:
 * duration and time only.
 */

export interface TurnFooter {
  readonly durationMs: number | null;
  readonly completedAt: string;
  readonly runningShells: number;
  readonly runningAgents: number;
}

type FooterThread = Pick<OrchestrationThread, "messages" | "activities" | "latestTurn" | "session">;

const ENDED_STATUSES: ReadonlySet<string> = new Set([
  "completed",
  "failed",
  "cancelled",
  "interrupted",
  "stopped",
]);

function isShellTaskType(taskType: string): boolean {
  const normalized = taskType.toLowerCase();
  return normalized.includes("bash") || normalized.includes("shell");
}

function taskPayload(activity: OrchestrationThreadActivity): {
  readonly taskId: string;
  readonly taskType?: string;
  readonly agentKind?: string;
  readonly agentId?: string;
  readonly status?: string;
  readonly endedAt?: string;
  readonly isBackgrounded?: boolean;
} | null {
  const payload = activity.payload;
  if (typeof payload !== "object" || payload === null) return null;
  const record = payload as Record<string, unknown>;
  if (typeof record.taskId !== "string") return null;
  return {
    taskId: record.taskId,
    ...(typeof record.taskType === "string" ? { taskType: record.taskType } : {}),
    ...(typeof record.agentKind === "string" ? { agentKind: record.agentKind } : {}),
    ...(typeof record.agentId === "string" ? { agentId: record.agentId } : {}),
    ...(typeof record.status === "string" ? { status: record.status } : {}),
    ...(typeof record.endedAt === "string" ? { endedAt: record.endedAt } : {}),
    ...(typeof record.isBackgrounded === "boolean"
      ? { isBackgrounded: record.isBackgrounded }
      : {}),
  };
}

function isAgentTask(task: NonNullable<ReturnType<typeof taskPayload>>): boolean {
  if (task.agentKind !== undefined) return task.agentKind === "agent";
  return (
    classifyTaskAgentKind({
      ...(task.taskType !== undefined ? { taskType: task.taskType } : {}),
      ...(task.agentId !== undefined ? { agentId: task.agentId } : {}),
    }) === "agent"
  );
}

function runningTaskCounts(
  thread: FooterThread,
  turnId: TurnId,
): { readonly shells: number; readonly agents: number } {
  const none = { shells: 0, agents: 0 };
  const status = thread.session?.status;
  if (status === undefined || status === "stopped" || status === "error") return none;
  const shells = new Set<string>();
  const agents = new Set<string>();
  const backgrounded = new Set<string>();
  for (const activity of thread.activities) {
    if (activity.kind !== "task.started" || activity.turnId !== turnId) continue;
    const task = taskPayload(activity);
    if (task === null) continue;
    if (task.taskType !== undefined && isShellTaskType(task.taskType)) shells.add(task.taskId);
    else if (isAgentTask(task)) agents.add(task.taskId);
    else continue;
    if (task.isBackgrounded === true) backgrounded.add(task.taskId);
  }
  if (shells.size === 0 && agents.size === 0) return none;
  const ended = new Set<string>();
  for (const activity of thread.activities) {
    if (activity.kind !== "task.updated" && activity.kind !== "task.completed") continue;
    const task = taskPayload(activity);
    if (task === null || (!shells.has(task.taskId) && !agents.has(task.taskId))) continue;
    if (task.isBackgrounded === true) backgrounded.add(task.taskId);
    if (
      activity.kind === "task.completed" ||
      task.endedAt !== undefined ||
      (task.status !== undefined && ENDED_STATUSES.has(task.status))
    ) {
      ended.add(task.taskId);
    }
  }
  let runningShells = 0;
  let runningAgents = 0;
  for (const taskId of backgrounded) {
    if (ended.has(taskId)) continue;
    if (shells.has(taskId)) runningShells += 1;
    else runningAgents += 1;
  }
  return { shells: runningShells, agents: runningAgents };
}

function elapsedMs(from: string | null, to: string): number | null {
  if (from === null) return null;
  const start = Date.parse(from);
  const end = Date.parse(to);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end < start) return null;
  return end - start;
}

function turnTiming(
  thread: FooterThread,
  turnId: TurnId,
): { readonly startedAt: string | null; readonly completedAt: string } | null {
  const latest = thread.latestTurn;
  if (latest !== null && latest.turnId === turnId) {
    if (latest.completedAt === null) return null;
    return { startedAt: latest.startedAt ?? latest.requestedAt, completedAt: latest.completedAt };
  }
  let userAt: string | null = null;
  let assistant: OrchestrationMessage | null = null;
  for (const message of thread.messages) {
    if (message.turnId !== turnId) continue;
    if (message.role === "user") userAt ??= message.createdAt;
    if (message.role === "assistant" && !message.streaming) assistant = message;
  }
  if (assistant === null) return null;
  return { startedAt: userAt, completedAt: assistant.updatedAt };
}

/** The footer of a completed turn; null while it runs or when the thread has no such turn. */
export function turnFooter(thread: FooterThread, turnId: TurnId): TurnFooter | null {
  const timing = turnTiming(thread, turnId);
  if (timing === null) return null;
  const running = runningTaskCounts(thread, turnId);
  return {
    durationMs: elapsedMs(timing.startedAt, timing.completedAt),
    completedAt: timing.completedAt,
    runningShells: running.shells,
    runningAgents: running.agents,
  };
}

/**
 * Every completed turn's footer in one pass, keyed by turn in the order of
 * the turns' first assistant messages — what `turnFooter` answers for each
 * of them, without walking the messages and activities once per turn. A
 * thread mid-flight changes on every activity delta, so the callers fold
 * it on every tick; O(T × (M + A)) per tick was the phone audit's first
 * finding (2026-09-15).
 */
export function turnFooters(thread: FooterThread): ReadonlyMap<TurnId, TurnFooter> {
  const order: TurnId[] = [];
  const userAt = new Map<TurnId, string>();
  const assistant = new Map<TurnId, OrchestrationMessage>();
  for (const message of thread.messages) {
    if (message.turnId === null) continue;
    if (message.role === "user") {
      if (!userAt.has(message.turnId)) userAt.set(message.turnId, message.createdAt);
    } else if (message.role === "assistant") {
      if (!assistant.has(message.turnId) && !order.includes(message.turnId)) {
        order.push(message.turnId);
      }
      if (!message.streaming) assistant.set(message.turnId, message);
    }
  }
  const running = runningTaskCountsByTurn(thread);
  const footers = new Map<TurnId, TurnFooter>();
  const latest = thread.latestTurn;
  for (const turnId of order) {
    let timing: { readonly startedAt: string | null; readonly completedAt: string } | null;
    if (latest !== null && latest.turnId === turnId) {
      timing =
        latest.completedAt === null
          ? null
          : { startedAt: latest.startedAt ?? latest.requestedAt, completedAt: latest.completedAt };
    } else {
      const last = assistant.get(turnId);
      timing =
        last === undefined
          ? null
          : { startedAt: userAt.get(turnId) ?? null, completedAt: last.updatedAt };
    }
    if (timing === null) continue;
    const counts = running.get(turnId) ?? { shells: 0, agents: 0 };
    footers.set(turnId, {
      durationMs: elapsedMs(timing.startedAt, timing.completedAt),
      completedAt: timing.completedAt,
      runningShells: counts.shells,
      runningAgents: counts.agents,
    });
  }
  return footers;
}

/** `runningTaskCounts` for every turn at once: two passes over the
    activities instead of two per turn. */
function runningTaskCountsByTurn(
  thread: FooterThread,
): ReadonlyMap<TurnId, { readonly shells: number; readonly agents: number }> {
  const counts = new Map<TurnId, { shells: number; agents: number }>();
  const status = thread.session?.status;
  if (status === undefined || status === "stopped" || status === "error") return counts;
  const tasks = new Map<string, { readonly turnId: TurnId; readonly shell: boolean }>();
  const backgrounded = new Set<string>();
  for (const activity of thread.activities) {
    if (activity.kind !== "task.started" || activity.turnId === null) continue;
    const task = taskPayload(activity);
    if (task === null) continue;
    if (task.taskType !== undefined && isShellTaskType(task.taskType)) {
      tasks.set(task.taskId, { turnId: activity.turnId, shell: true });
    } else if (isAgentTask(task)) {
      tasks.set(task.taskId, { turnId: activity.turnId, shell: false });
    } else continue;
    if (task.isBackgrounded === true) backgrounded.add(task.taskId);
  }
  if (tasks.size === 0) return counts;
  const ended = new Set<string>();
  for (const activity of thread.activities) {
    if (activity.kind !== "task.updated" && activity.kind !== "task.completed") continue;
    const task = taskPayload(activity);
    if (task === null || !tasks.has(task.taskId)) continue;
    if (task.isBackgrounded === true) backgrounded.add(task.taskId);
    if (
      activity.kind === "task.completed" ||
      task.endedAt !== undefined ||
      (task.status !== undefined && ENDED_STATUSES.has(task.status))
    ) {
      ended.add(task.taskId);
    }
  }
  for (const taskId of backgrounded) {
    if (ended.has(taskId)) continue;
    const task = tasks.get(taskId)!;
    const entry = counts.get(task.turnId) ?? { shells: 0, agents: 0 };
    if (task.shell) entry.shells += 1;
    else entry.agents += 1;
    counts.set(task.turnId, entry);
  }
  return counts;
}

/** `time` is `completedAt` in the user's timestamp format. */
export function turnFooterLabel(footer: TurnFooter, time: string): string {
  const parts = [
    footer.durationMs === null ? "Done" : `Done in ${formatDuration(footer.durationMs)}`,
    time,
  ];
  if (footer.runningShells > 0) {
    parts.push(
      `${footer.runningShells} ${footer.runningShells === 1 ? "shell" : "shells"} still running`,
    );
  }
  if (footer.runningAgents > 0) {
    parts.push(
      `${footer.runningAgents} ${footer.runningAgents === 1 ? "agent" : "agents"} still running`,
    );
  }
  return parts.join(" · ");
}
