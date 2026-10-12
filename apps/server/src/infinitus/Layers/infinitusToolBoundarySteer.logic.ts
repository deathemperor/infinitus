import type {
  OrchestrationV2DomainEvent,
  OrchestrationV2Run,
  OrchestrationV2TurnItem,
  RunId,
} from "@infinitus/contracts";

/**
 * The turn items whose end is a step of the running turn: the tools. A
 * subagent counts, as upstream's own boundary counted it (#1318); text,
 * reasoning, plans and requests are not steps. `failed` is a boundary too —
 * the model reads the failure next, which is where a steer belongs.
 */
const TOOL_ITEM_TYPES: ReadonlySet<OrchestrationV2TurnItem["type"]> = new Set([
  "command_execution",
  "file_change",
  "file_search",
  "web_search",
  "dynamic_tool",
  "subagent",
]);

export function isToolBoundaryItem(item: OrchestrationV2TurnItem): boolean {
  return (
    item.runId !== null &&
    TOOL_ITEM_TYPES.has(item.type) &&
    (item.status === "completed" || item.status === "failed")
  );
}

/** The `turn-item.updated` events that are a finished tool call of some run. */
export function toolBoundaryOf(event: OrchestrationV2DomainEvent): OrchestrationV2TurnItem | null {
  return event.type === "turn-item.updated" && isToolBoundaryItem(event.payload)
    ? event.payload
    : null;
}

/**
 * The queued run to send into `targetRunId` at this boundary: the first
 * `tool_boundary` row in queue order, past any idle rows ahead of it (head-only
 * would hold a steer behind an idle row until the turn ends, which is what
 * steer exists to avoid). Nothing while the target is not running — a stale
 * event, or the next turn's tool — or while the queue is held.
 */
export function toolBoundarySteerCandidate(
  runs: ReadonlyArray<OrchestrationV2Run>,
  targetRunId: RunId,
): RunId | undefined {
  const target = runs.find((run) => run.id === targetRunId);
  if (target === undefined || (target.status !== "running" && target.status !== "waiting")) {
    return undefined;
  }
  return runs
    .filter(
      (run) => run.status === "queued" && run.sendAt === "tool_boundary" && run.queueHeld !== true,
    )
    .toSorted(
      (left, right) =>
        (left.queuePosition ?? left.ordinal) - (right.queuePosition ?? right.ordinal) ||
        left.ordinal - right.ordinal,
    )[0]?.id;
}
