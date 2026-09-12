import type { OrchestrationThreadActivity, ThreadId, TurnId } from "@t3tools/contracts";

/**
 * Background subagents a Claude session left running (#974): the words of
 * the error row the adapter writes when a session exits with agents live,
 * and the rows the boot-time reconcile (#977) writes for a server that was
 * killed before it could.
 */

/** The prefix the reconcile's candidate query keys idempotence on. */
export const BACKGROUND_AGENTS_MESSAGE_PREFIX = "Session ended with ";

export function liveBackgroundAgentsMessage(count: number): string {
  return `${BACKGROUND_AGENTS_MESSAGE_PREFIX}${count} background ${count === 1 ? "agent" : "agents"} running — their work is not finished.`;
}

export interface OrphanedBackgroundAgent {
  readonly taskId: string;
  readonly turnId: TurnId | null;
  readonly title: string | null;
}

/**
 * The rows a graceful stop would have written (`ClaudeAdapter.ts`'s stop
 * path, as ingestion shapes them): one stopped row per agent, then the error
 * row naming the count. `ids` supplies one fresh id per row, agents first.
 */
export function orphanedBackgroundAgentRows(input: {
  readonly threadId: ThreadId;
  readonly agents: ReadonlyArray<OrphanedBackgroundAgent>;
  readonly ids: ReadonlyArray<OrchestrationThreadActivity["id"]>;
  readonly createdAt: string;
}): ReadonlyArray<OrchestrationThreadActivity> {
  const rows: Array<OrchestrationThreadActivity> = input.agents.map((agent, index) => ({
    id: input.ids[index]!,
    tone: "info",
    kind: "task.completed",
    summary: "Task stopped",
    payload: {
      taskId: agent.taskId,
      status: "stopped",
      agentKind: "agent",
      ...(agent.title !== null ? { title: agent.title } : {}),
    },
    turnId: agent.turnId,
    createdAt: input.createdAt,
  }));
  rows.push({
    id: input.ids[input.agents.length]!,
    tone: "error",
    kind: "runtime.error",
    summary: "Runtime error",
    payload: { message: liveBackgroundAgentsMessage(input.agents.length) },
    turnId: null,
    createdAt: input.createdAt,
  });
  return rows;
}
