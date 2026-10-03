import { resolveThreadWorkingStartedAt } from "@infinitus/client-runtime/state/models";
import {
  type AssetResource,
  type OrchestrationV2ExecutionNode,
  type OrchestrationV2PlanArtifact,
  type OrchestrationV2ProjectedTurnItem,
  type OrchestrationV2RunAttempt,
  type OrchestrationV2ThreadProjection,
  type OrchestrationV2TurnItem,
  type PlanId,
  type RunId,
  type ToolActivitySurface,
  type ToolActivityIcon,
  type ToolActivitySource,
} from "@infinitus/contracts";
import { extractToolActivityPresentation } from "@infinitus/client-runtime/work-log/tool-presentation";
import {
  classifyToolActivity,
  collectToolFilePaths,
  formatReadToolLabel,
  formatSearchToolLabel,
} from "@infinitus/shared/toolActivity";
import {
  contextCompactionLabel,
  workEntryIndicatesToolFailure,
} from "@infinitus/client-runtime/work-log/presentation";
import type { ThreadCheckpointSummary } from "@infinitus/client-runtime/state/thread-checkpoints";
import type {
  ThreadPendingApproval,
  ThreadPendingUserInput,
} from "@infinitus/client-runtime/state/thread-requests";
import type { ThreadRunSummary, ThreadRuntimeSummary } from "@infinitus/client-runtime/state/shell";
import { threadRuntimeHasInterruptibleRun } from "@infinitus/client-runtime/state/thread-execution";
import { turnItemIsWorkspacePreparation } from "@infinitus/client-runtime/state/turn-item-presentation";

import {
  isImageAttachment,
  type ChatAttachment,
  type ChatMessage,
  type ProposedPlan,
  type SessionPhase,
  type TurnDiffSummary,
} from "./types";
import * as DateTime from "effect/DateTime";
import * as Equal from "effect/Equal";
import { shallow } from "zustand/vanilla/shallow";

export { formatDuration } from "@infinitus/shared/orchestrationTiming";
export {
  workEntryDisplayIndicatesToolFailure,
  workEntryIndicatesToolFailure,
} from "@infinitus/client-runtime/work-log/presentation";

export type WorkLogToolLifecycleStatus =
  | "idle"
  | "inProgress"
  | "completed"
  | "failed"
  | "declined"
  | "stopped";

export interface WorkLogEntry {
<<<<<<< HEAD
  questionAnswer?: UserInputAttachmentAnswerPayload;
  id: string;
  createdAt: string;
  turnId?: TurnId | null;
  /** Stable provider identity across in-progress and completed lifecycle updates. */
  toolCallId?: string;
  label: string;
  detail?: string;
  viewedImagePath?: string;
  command?: string;
  rawCommand?: string;
  commandDescription?: string;
  changedFiles?: ReadonlyArray<string>;
  tone: "thinking" | "tool" | "info" | "error";
  toolTitle?: string;
  toolSurface?: import("@infinitus/contracts").ToolActivitySurface;
  toolIcon?: import("@infinitus/contracts").ToolActivityIcon;
  toolSource?: import("@infinitus/contracts").ToolActivitySource;
  toolData?: unknown;
  itemType?: ToolLifecycleItemType;
  requestKind?: PendingApproval["requestKind"];
  /** From runtime item / task payload `status` when present (e.g. tool.updated). */
  toolLifecycleStatus?: WorkLogToolLifecycleStatus;
  /** Originating orchestration activity kind (e.g. `user-input.requested`) for row chrome. */
  sourceActivityKind?: OrchestrationThreadActivity["kind"];
  /** Grouping key for subagent lifecycle rows (one row per agent). */
  taskId?: string;
  /** Agent role (subagent_type) for labeled timeline rows. */
  agentRole?: string;
  /**
   * Present on agent-spawn rows: one per workflow run or per-turn batch of
   * direct spawns. The row ("Kicked off N subagents") derives its live
   * status and member list from the agent panel model at render time.
   */
  agentSpawn?: {
    /** Workflow coordinator taskId, or null for a direct-spawn batch. */
    workflowId: string | null;
    agentTaskIds: ReadonlyArray<string>;
  };
=======
  readonly questionAnswer?: import("@infinitus/contracts").UserInputAttachmentAnswerPayload;
  readonly id: string;
  readonly createdAt: string;
  readonly runId?: RunId | null;
  readonly label: string;
  readonly detail?: string;
  readonly command?: string;
  readonly rawCommand?: string;
  readonly changedFiles?: ReadonlyArray<string>;
  readonly tone: "thinking" | "tool" | "info" | "error";
  readonly toolTitle?: string;
  readonly toolCallId?: string;
  readonly viewedImagePath?: string;
  readonly toolSurface?: ToolActivitySurface;
  readonly toolIcon?: ToolActivityIcon;
  readonly toolSource?: ToolActivitySource;
  readonly sourceActivityKind?: string;
  readonly taskId?: string;
  readonly agentRole?: string;
  readonly toolData?: unknown;
  readonly requestKind?: string;
  readonly itemType?: OrchestrationV2TurnItem["type"];
  readonly toolLifecycleStatus?: WorkLogToolLifecycleStatus;
  readonly structuredPayload?: OrchestrationV2TurnItem;
  readonly sourceItemType?: OrchestrationV2TurnItem["type"];
  readonly projectedItem?: OrchestrationV2ProjectedTurnItem;
>>>>>>> upstream-sync-e8545b293-upstream-renamed
}

export type PendingApproval = ThreadPendingApproval;
export type PendingUserInput = ThreadPendingUserInput;

export interface ActivePlanState {
  readonly createdAt: string;
  readonly runId: RunId | null;
  readonly explanation?: string | null;
  readonly steps: Array<{
    readonly step: string;
    readonly status: "pending" | "inProgress" | "completed";
    readonly durationMs?: number;
  }>;
}

export interface LatestProposedPlanState {
  readonly id: PlanId;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly runId: RunId | null;
  readonly planMarkdown: string;
  readonly status: OrchestrationV2PlanArtifact["status"];
}

export type TimelineAttempt = Pick<
  OrchestrationV2RunAttempt,
  "id" | "runId" | "attemptOrdinal" | "rootNodeId" | "status"
>;

export type TimelineEntry = (
  | {
      readonly id: string;
      readonly kind: "message";
      readonly createdAt: string;
      readonly message: ChatMessage;
      readonly projectedItem?: OrchestrationV2ProjectedTurnItem;
    }
  | {
      readonly id: string;
      readonly kind: "proposed-plan";
      readonly createdAt: string;
      readonly proposedPlan: ProposedPlan;
    }
  | {
      readonly id: string;
      readonly kind: "work";
      readonly createdAt: string;
      readonly entry: WorkLogEntry;
    }
  | {
      readonly id: string;
      readonly kind: "event";
      readonly createdAt: string;
      readonly projectedItem: OrchestrationV2ProjectedTurnItem;
    }
) & {
  /** V2 identity resolved from the item's execution node, when locally available. */
  readonly attempt?: TimelineAttempt;
};

export function workLogEntryIsToolLike(entry: WorkLogEntry): boolean {
  return (
    entry.tone === "tool" ||
    entry.tone === "thinking" ||
    entry.tone === "error" ||
    entry.command !== undefined ||
    entry.requestKind !== undefined
  );
}

/** Severe failures keep the red treatment ordinary tool failures lost: provider
 *  runtime errors mean the turn or a core side effect broke, not that a
 *  command exited nonzero. */
export function workEntrySignalsSevereFailure(entry: WorkLogEntry): boolean {
  return entry.itemType === "error";
}

export function workEntryIndicatesToolSuccess(entry: WorkLogEntry): boolean {
  if (
    !workLogEntryIsToolLike(entry) ||
    workEntryIndicatesToolFailure(entry) ||
    (entry.tone === "thinking" && entry.itemType !== "reasoning")
  ) {
    return false;
  }
  const status = entry.toolLifecycleStatus;
  return (
    status !== "failed" &&
    status !== "declined" &&
    status !== "inProgress" &&
    status !== "stopped" &&
    status !== "idle"
  );
}

/** Tool-like row with neither clear success nor failure (empty, incomplete, in progress, etc.). */
export function workEntryIndicatesToolNeutralStatus(entry: WorkLogEntry): boolean {
  return (
    workLogEntryIsToolLike(entry) &&
    !workEntryIndicatesToolFailure(entry) &&
    !workEntryIndicatesToolSuccess(entry)
  );
}

export function isLatestRunSettled(
  latestRun: Pick<ThreadRunSummary, "runId" | "startedAt" | "completedAt" | "status"> | null,
  runtime: Pick<ThreadRuntimeSummary, "status" | "activeRunId"> | null,
): boolean {
  if (latestRun === null) return false;
  if (
    latestRun.status === "preparing" ||
    latestRun.status === "queued" ||
    latestRun.status === "starting" ||
    latestRun.status === "running" ||
    latestRun.status === "waiting"
  )
    return false;
  return runtime?.activeRunId !== latestRun.runId;
}

export function deriveActiveWorkStartedAt(
  latestRun: Pick<
    ThreadRunSummary,
    "runId" | "startedAt" | "requestedAt" | "completedAt" | "status"
  > | null,
  runtime: Pick<ThreadRuntimeSummary, "status" | "activeRunId" | "activityStartedAt"> | null,
  sendStartedAt: string | null,
): string | null {
  const startedAt = resolveThreadWorkingStartedAt({ latestRun, runtime });
  // Local dispatch has a clock only until the server supplies the owning run.
  return startedAt ?? (runtime?.activeRunId == null ? sendStartedAt : null);
}

export function derivePendingApprovals(
  approvals: ReadonlyArray<ThreadPendingApproval>,
): ThreadPendingApproval[] {
  return [...approvals].toSorted((left, right) => left.createdAt.localeCompare(right.createdAt));
}

export function derivePendingUserInputs(
  inputs: ReadonlyArray<ThreadPendingUserInput>,
): ThreadPendingUserInput[] {
  return [...inputs].toSorted((left, right) => left.createdAt.localeCompare(right.createdAt));
}

export function deriveActivePlanState(
  projection: OrchestrationV2ThreadProjection | null,
  latestRunId: RunId | undefined,
): ActivePlanState | null {
  if (projection === null) return null;
  const plans = projection.plans.filter((plan) => plan.kind === "todo_list");
  const plan =
    [...plans].toReversed().find((candidate) => candidate.runId === latestRunId) ??
    plans.at(-1) ??
    null;
  if (plan === null || plan.steps.length === 0) return null;
  return {
    createdAt: planItemTime(projection, plan.id),
    runId: plan.runId,
    explanation: plan.explanation ?? null,
    steps: plan.steps.map(({ text, status, durationMs }) => ({
      step: text,
      status: status === "running" ? "inProgress" : status,
      ...(durationMs === undefined ? {} : { durationMs }),
    })),
  };
}

function planItemTime(projection: OrchestrationV2ThreadProjection, planId: PlanId): string {
  const item = projection.turnItems.findLast(
    (candidate) =>
      (candidate.type === "proposed_plan" || candidate.type === "todo_list") &&
      candidate.planId === planId,
  );
  return DateTime.formatIso(item?.updatedAt ?? projection.updatedAt);
}

function toLatestProposedPlanState(
  projection: OrchestrationV2ThreadProjection,
  plan: Extract<OrchestrationV2PlanArtifact, { readonly kind: "proposed_plan" }>,
): LatestProposedPlanState {
  const updatedAt = planItemTime(projection, plan.id);
  return {
    id: plan.id,
    createdAt: updatedAt,
    updatedAt,
    runId: plan.runId,
    planMarkdown: plan.markdown,
    status: plan.status,
  };
}

export function findLatestProposedPlan(
  projection: OrchestrationV2ThreadProjection | null,
  latestRunId: RunId | string | null | undefined,
): LatestProposedPlanState | null {
  if (projection === null) return null;
  const plans = projection.plans.filter((plan) => plan.kind === "proposed_plan");
  const candidates = latestRunId ? plans.filter((plan) => plan.runId === latestRunId) : plans;
  const plan = [...(candidates.length > 0 ? candidates : plans)]
    .toSorted(
      (left, right) =>
        planItemTime(projection, left.id).localeCompare(planItemTime(projection, right.id)) ||
        left.id.localeCompare(right.id),
    )
    .at(-1);
  return plan === undefined ? null : toLatestProposedPlanState(projection, plan);
}

export function hasActionableProposedPlan(plan: LatestProposedPlanState | null): boolean {
  return plan?.status === "active";
}

<<<<<<< HEAD
/**
 * Quiet-timeline guarantee: the work log carries the parent's narrative plus
 * at most one row per agent. Everything an agent does internally lives in the
 * Agents surface:
 * - timelineBypass rows (Codex children, workflow members) never render here;
 * - tool rows attributed to an owning agent (payload.agentId) are re-homed
 *   (deriveAgentWorkLogEntries hands them to the spawn member row, #1567);
 * - task.progress ticks collapse into one row per taskId;
 * - task.updated is fold input only (status patches are not narrative).
 * Unattributed rows stay unless a linked agent row replaces their launch;
 * failed launches stay so the only terminal signal cannot disappear.
 */
/** Agent (non-background) task.started rows seed spawn CTA batches. */
function isAgentTaskStartedActivity(activity: OrchestrationThreadActivity): boolean {
  const payload =
    activity.payload && typeof activity.payload === "object"
      ? (activity.payload as Record<string, unknown>)
      : null;
  if (!payload || typeof payload.taskId !== "string") {
    return false;
  }
  return !isBackgroundTaskActivity(payload);
}
=======
const STANDALONE_V2_ITEM_TYPES = new Set<OrchestrationV2ProjectedTurnItem["item"]["type"]>([
  "fork",
  "handoff",
  "run_interrupt_request",
  "run_interrupt_result",
  "subagent",
]);
>>>>>>> upstream-sync-e8545b293-upstream-renamed

const PERSISTENT_RESOURCE_V2_ITEM_TYPES = new Set<OrchestrationV2TurnItem["type"]>([
  "fork",
  "thread_created",
]);

<<<<<<< HEAD
export function deriveWorkLogEntries(
  activities: ReadonlyArray<OrchestrationThreadActivity>,
): WorkLogEntry[] {
  const ordered = [...activities].toSorted(compareActivitiesByOrder);
  // A launch tool and its task lifecycle describe the same run. Only hide
  // launch rows once their tool-use id has an agent row to replace them.
  const agentLaunchToolIds = new Set<string>();
  for (const activity of ordered) {
    if (
      (activity.kind === "task.started" ||
        activity.kind === "task.progress" ||
        activity.kind === "task.completed") &&
      isAgentTaskStartedActivity(activity)
    ) {
      const toolUseId = asTrimmedString(asRecord(activity.payload)?.toolUseId);
      if (toolUseId) agentLaunchToolIds.add(toolUseId);
    }
  }
  const entries: DerivedWorkLogEntry[] = [];
  for (const activity of foldUserInputActivities(ordered)) {
    if (
      isWorktreeSetupActivity(activity.kind) &&
      (activity.tone !== "error" || activity.kind === "worktree-setup")
    ) {
      continue;
    }
    if (activity.kind === "tool.started") continue;
    // Agent task.started rows are CTA seeds: they carry the true spawn turn,
    // which is the batch key (completions of background subagents arrive
    // under later synthetic turns and must not start new batches). They
    // collapse into the batch's single CTA row, never render standalone.
    if (activity.kind === "task.started" && !isAgentTaskStartedActivity(activity)) continue;
    if (activity.kind === "task.updated") continue;
    if (activity.kind === "tool.progress") continue;
    if (activity.kind === "context-window.updated") continue;
    if (activity.kind === "turn.plan.updated") continue;
    if (activity.summary === "Checkpoint captured") continue;
    if (isNoContentRuntimeWarning(activity)) continue;
    if (isPlanBoundaryToolActivity(activity)) continue;
    if (isAgentInternalActivity(activity)) continue;
    const entry = toDerivedWorkLogEntry(activity);
    // Native agent launches get their visible row from task.started. Defer
    // their active tool row so another launch cannot duplicate the batch.
    if (
      activity.kind === "tool.updated" &&
      entry.itemType === "collab_agent_tool_call" &&
      entry.toolLifecycleStatus === "inProgress" &&
      entry.tone !== "error"
    ) {
      const toolName = asRecord(asRecord(activity.payload)?.data)?.toolName;
      if (toolName === "Agent" || toolName === "Task") continue;
    }
    if (
      (activity.kind === "tool.updated" || activity.kind === "tool.completed") &&
      entry.toolCallId &&
      agentLaunchToolIds.has(entry.toolCallId) &&
      entry.tone !== "error" &&
      entry.toolLifecycleStatus !== "failed"
    ) {
      continue;
    }
    entries.push(entry);
  }
  return collapseDerivedWorkLogEntries(entries);
}

const EMPTY_AGENT_WORK_LOG_ENTRIES: ReadonlyMap<string, ReadonlyArray<WorkLogEntry>> = new Map();

/**
 * The tool rows the quiet-timeline filter re-homes (#1567): every attributed
 * tool activity, grouped by its owning agent's taskId and collapsed per tool
 * call the same way the parent's rows are, so a spawn member can render its
 * agent's work with the chrome the main thread uses. Nothing in the chat
 * timeline reads this map; only the expanded member row does.
 */
export function deriveAgentWorkLogEntries(
  activities: ReadonlyArray<OrchestrationThreadActivity>,
): ReadonlyMap<string, ReadonlyArray<WorkLogEntry>> {
  // Attributed rows are a small minority of a thread; pick them out before
  // sorting, and hand back one shared empty map so the timeline row context
  // keeps its identity on threads without subagents.
  const attributed: Array<[OrchestrationThreadActivity, string]> = [];
  for (const activity of activities) {
    if (activity.kind !== "tool.updated" && activity.kind !== "tool.completed") continue;
    const agentId = asTrimmedString(asRecord(activity.payload)?.agentId);
    if (!agentId || isPlanBoundaryToolActivity(activity)) continue;
    attributed.push([activity, agentId]);
  }
  if (attributed.length === 0) return EMPTY_AGENT_WORK_LOG_ENTRIES;
  attributed.sort(([left], [right]) => compareActivitiesByOrder(left, right));
  const byAgent = new Map<string, DerivedWorkLogEntry[]>();
  const rowIndexByToolCall = new Map<string, number>();
  for (const [activity, agentId] of attributed) {
    const entry = toDerivedWorkLogEntry(activity);
    const entries = byAgent.get(agentId) ?? [];
    if (entries.length === 0) byAgent.set(agentId, entries);
    // One row per tool call across its lifecycle; a completed row is final
    // (a duplicate completion starts a new row rather than rewriting it).
    const key = entry.toolCallId ? `${agentId}:${entry.toolCallId}` : undefined;
    const existingIndex = key === undefined ? undefined : rowIndexByToolCall.get(key);
    const existing = existingIndex === undefined ? undefined : entries[existingIndex];
    if (existing && existing.sourceActivityKind !== "tool.completed") {
      // The row keeps its first identity so the member's list has stable keys
      // across the call's lifecycle.
      entries[existingIndex!] = {
        ...mergeDerivedWorkLogEntries(existing, entry),
        id: existing.id,
        createdAt: existing.createdAt,
      };
      continue;
    }
    if (key !== undefined) rowIndexByToolCall.set(key, entries.length);
    entries.push(entry);
  }
  return byAgent;
}

/** Adapters forward unknown wire-only SDK messages (background_tasks_changed,
 *  commands_changed, ...) as runtime warnings. The suffix comes from
 *  describeUnknownSdkMessage in the Claude adapter; a row with no displayable
 *  text carries nothing a user can act on, so it does not render. */
function isNoContentRuntimeWarning(activity: OrchestrationThreadActivity): boolean {
=======
export function timelineEntryIsPersistentResourceCard(entry: TimelineEntry): boolean {
>>>>>>> upstream-sync-e8545b293-upstream-renamed
  return (
    entry.kind === "event" && PERSISTENT_RESOURCE_V2_ITEM_TYPES.has(entry.projectedItem.item.type)
  );
}

function projectedItemCreatedAt(row: OrchestrationV2ProjectedTurnItem): string {
  return DateTime.formatIso(row.item.startedAt ?? row.item.updatedAt);
}

function projectedWorkEntryStatus(
  item: OrchestrationV2TurnItem,
): NonNullable<WorkLogEntry["toolLifecycleStatus"]> {
  switch (item.status) {
    case "pending":
    case "running":
    case "waiting":
      return "inProgress";
    case "completed":
      return "completed";
    case "idle":
      return "idle";
    case "failed":
      return "failed";
    case "cancelled":
    case "interrupted":
      return "stopped";
  }
}

function projectedWorkEntryTone(item: OrchestrationV2TurnItem): WorkLogEntry["tone"] {
  if (item.type === "error") return "info";
  if (item.type === "reasoning") return "thinking";
  switch (item.type) {
    case "command_execution":
    case "file_change":
    case "file_search":
    case "web_search":
    case "dynamic_tool":
    case "subagent":
    case "thread_created":
    case "user_input_request":
    case "approval_request":
      return "tool";
    default:
      return "info";
  }
}

export function providerErrorPresentation(
  item: Extract<OrchestrationV2TurnItem, { readonly type: "error" }>,
): { readonly label: string; readonly detail: string } {
  if (item.retry === undefined) {
    return {
      label:
        item.failure.class === "usage_limit"
          ? "Usage limit reached"
          : item.title?.trim() || "Provider error",
      detail: item.failure.message,
    };
  }
  const progress =
    item.retry.maxAttempts === null
      ? `${item.retry.attempt}`
      : `${item.retry.attempt}/${item.retry.maxAttempts}`;
  const label =
    item.status === "running"
      ? `Retrying provider (${progress})`
      : item.status === "completed"
        ? `Provider recovered (${progress} retries)`
        : item.status === "failed"
          ? `${item.failure.class === "usage_limit" ? "Usage limit reached" : "Provider error"} after ${progress} retries`
          : `Provider retry stopped (${progress})`;
  const retryDelay =
    item.status === "running" && item.retry.retryDelayMs !== null && item.retry.retryDelayMs > 0
      ? item.retry.retryDelayMs < 1_000
        ? ` Retrying in ${item.retry.retryDelayMs}ms.`
        : ` Retrying in ${(item.retry.retryDelayMs / 1_000).toFixed(1).replace(/\.0$/u, "")}s.`
      : "";
  return {
    label,
    detail: `${item.failure.message}${retryDelay}`,
  };
}

function projectedWorkEntry(row: OrchestrationV2ProjectedTurnItem): WorkLogEntry {
  const { item } = row;
  const title = item.title?.trim() || null;
  const common = {
    id: item.id,
    createdAt: projectedItemCreatedAt(row),
    runId: item.runId,
    tone: projectedWorkEntryTone(item),
    itemType: item.type,
    toolLifecycleStatus: projectedWorkEntryStatus(item),
    structuredPayload: item,
    projectedItem: row,
    ...extractToolActivityPresentation(item),
  } as const;

  switch (item.type) {
    case "thread_created":
      return {
        ...common,
        label: "Created thread",
      };
    case "compaction":
      return {
        ...common,
        label: contextCompactionLabel(item),
        sourceActivityKind: "context-compaction",
        ...(item.summary ? { detail: item.summary } : {}),
      };
    case "reasoning":
      return {
        ...common,
        label: title ?? "Thinking",
        ...(item.text ? { detail: item.text } : {}),
      };
    case "command_execution":
      return {
        ...common,
        label: title ?? "Ran command",
        command: item.input,
        rawCommand: item.input,
        toolTitle: title ?? "Command",
        toolData: item,
      };
    case "file_change": {
      return {
        ...common,
        label:
          title ??
          (item.changes !== undefined && item.changes.length > 1
            ? `Changed ${item.changes.length} files`
            : `Changed ${item.fileName}`),
        changedFiles: item.changes?.map((change) => change.path) ?? [item.fileName],
        toolTitle: title ?? "File change",
        toolData: item,
      };
    }
<<<<<<< HEAD
  }
  if (viewedImagePath) {
    entry.viewedImagePath = viewedImagePath;
  }
  if (commandPreview.command) {
    entry.command = commandPreview.command;
  }
  if (commandPreview.rawCommand) {
    entry.rawCommand = commandPreview.rawCommand;
  }
  const commandDescription =
    itemType === "command_execution" ? asTrimmedString(asRecord(payload?.data)?.description) : null;
  if (commandDescription) {
    entry.commandDescription = normalizeInlinePreview(commandDescription);
  }
  if (changedFiles.length > 0) {
    entry.changedFiles = changedFiles;
  }
  if (title) {
    entry.toolTitle = title;
  }
  if (toolPresentation.toolSurface) {
    entry.toolSurface = toolPresentation.toolSurface;
  }
  if (toolPresentation.toolIcon) {
    entry.toolIcon = toolPresentation.toolIcon;
  }
  if (toolPresentation.toolSource) {
    entry.toolSource = toolPresentation.toolSource;
  }
  if (itemType === "mcp_tool_call") {
    const data = asRecord(payload?.data);
    const toolData = typeof data?.toolName === "string" ? (data.item ?? data) : data?.item;
    if (toolData !== undefined) {
      entry.toolData = toolData;
=======
    case "file_search":
      return {
        ...common,
        label: title ?? formatSearchToolLabel(item) ?? "Searched files",
        ...(item.pattern ? { detail: item.pattern } : {}),
        toolTitle: title ?? "File search",
        toolData: item,
      };
    case "web_search":
      return {
        ...common,
        label: title ?? "Searched the web",
        ...(item.patterns?.length ? { detail: item.patterns.join(", ") } : {}),
        toolTitle: title ?? "Web search",
        toolData: item,
      };
    case "checkpoint":
      return {
        ...common,
        label: title ?? "Checkpoint captured",
        changedFiles: item.files.map((file) => file.path),
        toolData: item,
      };
    case "system_notice":
      return {
        ...common,
        label: item.message,
        sourceActivityKind: "runtime.warning",
      };
    case "error": {
      const presentation = providerErrorPresentation(item);
      return {
        ...common,
        ...presentation,
        ...(item.failure.class === "usage_limit" && item.status !== "completed"
          ? { sourceActivityKind: "runtime.warning" }
          : item.retry === undefined
            ? { sourceActivityKind: "runtime.error" }
            : {}),
        toolData: item,
      };
>>>>>>> upstream-sync-e8545b293-upstream-renamed
    }
    case "dynamic_tool": {
      const classified = classifyToolActivity({
        itemType: "dynamic_tool_call",
        data: { toolName: item.toolName ?? undefined, input: item.input },
      });
      const [readPath] = collectToolFilePaths({ input: item.input });
      return {
        ...common,
        label:
          title ??
          (classified === "read"
            ? formatReadToolLabel(readPath ?? "")
            : classified === "search"
              ? (formatSearchToolLabel({ input: item.input }) ?? item.toolName ?? "Tool call")
              : (item.toolName ?? "Tool call")),
        toolTitle: title ?? item.toolName ?? "Tool",
        toolData: { input: item.input, output: item.output },
      };
    }
    case "approval_request":
      return {
        ...common,
        label: title ?? "Approval requested",
        detail: item.prompt ?? item.requestKind,
        toolData: item,
      };
    case "user_input_request":
      return {
        ...common,
        label: title ?? (item.questionAnswer ? "Answered questions" : "Input requested"),
        ...(item.questionAnswer ? { questionAnswer: item.questionAnswer } : {}),
        toolData: item,
      };
    default:
      return {
        ...common,
        label: title ?? item.type.replaceAll("_", " "),
        toolData: item,
      };
  }
}

/**
 * Builds the web timeline in the exact order committed by `visibleTurnItems`.
 * Committed rows are presented directly from their projected item. Queued
 * input is absent by construction until dispatch creates its user turn item.
 * Persistent client-owned messages are inserted by timestamp without sorting
 * the canonical sequence. True optimistic sends remain appended afterward.
 */
export interface TimelineEntriesInput {
  readonly visibleTurnItems: ReadonlyArray<OrchestrationV2ProjectedTurnItem>;
  readonly optimisticMessages: ReadonlyArray<ChatMessage>;
  readonly anchoredMessages?: ReadonlyArray<ChatMessage>;
  readonly attachmentUrlById?: ReadonlyMap<string, string>;
  readonly attempts?: ReadonlyArray<OrchestrationV2RunAttempt>;
  readonly nodes?: ReadonlyArray<OrchestrationV2ExecutionNode>;
  readonly plans?: ReadonlyArray<OrchestrationV2PlanArtifact>;
}

export interface TimelineEntriesProjection {
  readonly input: TimelineEntriesInput;
  readonly entries: TimelineEntry[];
}

export function deriveTimelineEntriesFromVisibleTurnItems(
  input: TimelineEntriesInput,
): TimelineEntry[] {
  const committedMessageIds = new Set<string>();
  const entries: TimelineEntry[] = [];
  const attemptByRootNodeId = new Map(
    (input.attempts ?? []).map((attempt) => [attempt.rootNodeId, attempt] as const),
  );
  const nodeById = new Map((input.nodes ?? []).map((node) => [node.id, node] as const));
  const planById = new Map((input.plans ?? []).map((plan) => [plan.id, plan] as const));

  const resolveAttempt = (item: OrchestrationV2TurnItem): TimelineAttempt | undefined => {
    if (item.nodeId === null || item.runId === null) return undefined;
    let nodeId: OrchestrationV2ExecutionNode["id"] | null = item.nodeId;
    const visited = new Set<OrchestrationV2ExecutionNode["id"]>();
    while (nodeId !== null && !visited.has(nodeId)) {
      visited.add(nodeId);
      const directAttempt = attemptByRootNodeId.get(nodeId);
      if (directAttempt?.runId === item.runId) return directAttempt;
      const node = nodeById.get(nodeId);
      if (node === undefined) return undefined;
      const rootAttempt = attemptByRootNodeId.get(node.rootNodeId);
      if (rootAttempt?.runId === item.runId) return rootAttempt;
      nodeId = node.parentNodeId;
    }
    return undefined;
  };

  const foldedAnswerMessageIds = new Set(
    input.visibleTurnItems.flatMap(({ item }) =>
      item.type === "user_input_request" && item.questionAnswer
        ? [`async-answer:${item.questionAnswer.requestId}`]
        : [],
    ),
  );
  for (const row of input.visibleTurnItems) {
    const { item } = row;
    if (turnItemIsWorkspacePreparation(item)) continue;
    // Task progress belongs in the composer, not between conversation entries.
    if (item.type === "todo_list" || item.type === "checkpoint") continue;
    if (item.type === "user_message" && foldedAnswerMessageIds.has(item.messageId)) continue;
    const createdAt = projectedItemCreatedAt(row);
    const attempt = resolveAttempt(item);
    const attemptMetadata = attempt === undefined ? {} : { attempt };
    if (item.type === "notification") {
      entries.push({
        id: item.id,
        kind: "work",
        createdAt,
        entry: {
          id: item.id,
          createdAt,
          runId: item.runId,
          label: item.summary,
          tone: "info",
          itemType: item.type,
          structuredPayload: item,
          projectedItem: row,
        },
        ...attemptMetadata,
      });
      continue;
    }
    if (item.type === "user_message" || item.type === "assistant_message") {
      const message: ChatMessage = {
        id: item.messageId,
        role: item.type === "user_message" ? "user" : "assistant",
        text: item.text,
        ...(item.type === "user_message" && item.context ? { context: item.context } : {}),
        ...((item.attachments?.length ?? 0) > 0
          ? {
              attachments: (item.attachments ?? []).map((attachment) => {
                const previewUrl = input.attachmentUrlById?.get(attachment.id);
                return previewUrl ? { ...attachment, previewUrl } : attachment;
              }),
            }
          : {}),
        runId: item.runId,
        streaming: item.type === "assistant_message" && item.streaming,
        ...(item.type === "user_message"
          ? {
              createdBy: item.createdBy,
              creationSource: item.creationSource,
              ...(item.senderThreadId !== undefined ? { senderThreadId: item.senderThreadId } : {}),
              ...(item.scheduledTaskId !== undefined
                ? { scheduledTaskId: item.scheduledTaskId }
                : {}),
            }
          : {}),
        createdAt,
        updatedAt: DateTime.formatIso(item.updatedAt),
        ...(item.type === "user_message" ? { inputIntent: item.inputIntent } : {}),
      };
      committedMessageIds.add(message.id);
      entries.push({
        id: message.id,
        kind: "message",
        createdAt,
        message,
        projectedItem: row,
        ...attemptMetadata,
      });
      continue;
    }

<<<<<<< HEAD
function shouldCollapseToolLifecycleEntries(
  previous: DerivedWorkLogEntry,
  next: DerivedWorkLogEntry,
): boolean {
  if (
    previous.sourceActivityKind !== "tool.updated" &&
    previous.sourceActivityKind !== "tool.completed"
  ) {
    return false;
  }
  if (next.sourceActivityKind !== "tool.updated" && next.sourceActivityKind !== "tool.completed") {
    return false;
  }
  if (previous.turnId !== next.turnId) {
    return false;
  }
  if (previous.sourceActivityKind === "tool.completed") {
    return false;
  }
  if (
    previous[workLogCollapseKey] !== undefined &&
    previous[workLogCollapseKey] === next[workLogCollapseKey]
  ) {
    return true;
  }
  return (
    previous.toolCallId !== undefined &&
    next.toolCallId === undefined &&
    previous.itemType === next.itemType &&
    normalizeCompactToolLabel(previous.toolTitle ?? previous.label) ===
      normalizeCompactToolLabel(next.toolTitle ?? next.label)
  );
}

function mergeDerivedWorkLogEntries(
  previous: DerivedWorkLogEntry,
  next: DerivedWorkLogEntry,
): DerivedWorkLogEntry {
  const changedFiles = mergeChangedFiles(previous.changedFiles, next.changedFiles);
  const detail = next.detail ?? previous.detail;
  const viewedImagePath = next.viewedImagePath ?? previous.viewedImagePath;
  const command = next.command ?? previous.command;
  const rawCommand = next.rawCommand ?? previous.rawCommand;
  const commandDescription = next.commandDescription ?? previous.commandDescription;
  const toolTitle = next.toolTitle ?? previous.toolTitle;
  const toolSurface = next.toolSurface ?? previous.toolSurface;
  const toolIcon = next.toolIcon ?? previous.toolIcon;
  const toolSource = next.toolSource ?? previous.toolSource;
  const itemType = next.itemType ?? previous.itemType;
  const requestKind = next.requestKind ?? previous.requestKind;
  const collapseKey = next[workLogCollapseKey] ?? previous[workLogCollapseKey];
  const toolCallId = next.toolCallId ?? previous.toolCallId;
  const toolLifecycleStatus = next.toolLifecycleStatus ?? previous.toolLifecycleStatus;
  const toolData = next.toolData ?? previous.toolData;
  return {
    ...previous,
    ...next,
    ...(detail ? { detail } : {}),
    ...(viewedImagePath ? { viewedImagePath } : {}),
    ...(command ? { command } : {}),
    ...(rawCommand ? { rawCommand } : {}),
    ...(commandDescription ? { commandDescription } : {}),
    ...(changedFiles.length > 0 ? { changedFiles } : {}),
    ...(toolTitle ? { toolTitle } : {}),
    ...(toolSurface ? { toolSurface } : {}),
    ...(toolIcon ? { toolIcon } : {}),
    ...(toolSource ? { toolSource } : {}),
    ...(itemType ? { itemType } : {}),
    ...(requestKind ? { requestKind } : {}),
    ...(collapseKey ? { [workLogCollapseKey]: collapseKey } : {}),
    ...(toolCallId ? { toolCallId } : {}),
    ...(toolLifecycleStatus !== undefined ? { toolLifecycleStatus } : {}),
    ...(toolData !== undefined ? { toolData } : {}),
  };
}

function mergeChangedFiles(
  previous: ReadonlyArray<string> | undefined,
  next: ReadonlyArray<string> | undefined,
): string[] {
  const merged = [...(previous ?? []), ...(next ?? [])];
  if (merged.length === 0) {
    return [];
  }
  return [...new Set(merged)];
}

function deriveToolLifecycleCollapseKey(entry: DerivedWorkLogEntry): string | undefined {
  // Subagent lifecycle rows collapse by agent identity: one row per agent,
  // progress ticks fold into it, the terminal row wins the label.
  if (
    entry.taskId &&
    (entry.sourceActivityKind === "task.progress" || entry.sourceActivityKind === "task.completed")
  ) {
    return `task${entry.taskId}`;
  }
  if (
    entry.sourceActivityKind !== "tool.updated" &&
    entry.sourceActivityKind !== "tool.completed"
  ) {
    return undefined;
  }
  if (entry.toolCallId) {
    return `tool:${entry.turnId ?? "no-turn"}:${entry.toolCallId}`;
  }
  const normalizedLabel = normalizeCompactToolLabel(entry.toolTitle ?? entry.label);
  const detail = entry.detail?.trim() ?? "";
  const itemType = entry.itemType ?? "";
  if (normalizedLabel.length === 0 && detail.length === 0 && itemType.length === 0) {
    return undefined;
  }
  return [itemType, normalizedLabel, detail].join("\u001f");
}

function normalizeCompactToolLabel(value: string): string {
  return value.replace(/\s+(?:complete|completed)\s*$/i, "").trim();
}

function toLatestProposedPlanState(proposedPlan: ProposedPlan): LatestProposedPlanState {
  return {
    id: proposedPlan.id,
    createdAt: proposedPlan.createdAt,
    updatedAt: proposedPlan.updatedAt,
    turnId: proposedPlan.turnId,
    planMarkdown: proposedPlan.planMarkdown,
    implementedAt: proposedPlan.implementedAt,
    implementationThreadId: proposedPlan.implementationThreadId,
  };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
}

function asTrimmedString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function asNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function trimMatchingOuterQuotes(value: string): string {
  const trimmed = value.trim();
  if (
    (trimmed.startsWith("'") && trimmed.endsWith("'")) ||
    (trimmed.startsWith('"') && trimmed.endsWith('"'))
  ) {
    const unquoted = trimmed.slice(1, -1).trim();
    return unquoted.length > 0 ? unquoted : trimmed;
  }
  return trimmed;
}

function executableBasename(value: string): string | null {
  const trimmed = trimMatchingOuterQuotes(value);
  if (trimmed.length === 0) {
    return null;
  }
  const normalized = trimmed.replace(/\\/g, "/");
  const segments = normalized.split("/");
  const last = segments.at(-1)?.trim() ?? "";
  return last.length > 0 ? last.toLowerCase() : null;
}

function splitExecutableAndRest(value: string): { executable: string; rest: string } | null {
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return null;
  }

  if (trimmed.startsWith('"') || trimmed.startsWith("'")) {
    const quote = trimmed.charAt(0);
    const closeIndex = trimmed.indexOf(quote, 1);
    if (closeIndex <= 0) {
      return null;
    }
    return {
      executable: trimmed.slice(0, closeIndex + 1),
      rest: trimmed.slice(closeIndex + 1).trim(),
    };
  }

  const firstWhitespace = trimmed.search(/\s/);
  if (firstWhitespace < 0) {
    return {
      executable: trimmed,
      rest: "",
    };
  }

  return {
    executable: trimmed.slice(0, firstWhitespace),
    rest: trimmed.slice(firstWhitespace).trim(),
  };
}

const SHELL_WRAPPER_SPECS = [
  {
    executables: ["pwsh", "pwsh.exe", "powershell", "powershell.exe"],
    wrapperFlagPattern: /(?:^|\s)-command\s+/i,
  },
  {
    executables: ["cmd", "cmd.exe"],
    wrapperFlagPattern: /(?:^|\s)\/c\s+/i,
  },
  {
    executables: ["bash", "sh", "zsh"],
    wrapperFlagPattern: /(?:^|\s)-(?:l)?c\s+/i,
  },
] as const;

function findShellWrapperSpec(shell: string) {
  return SHELL_WRAPPER_SPECS.find((spec) =>
    (spec.executables as ReadonlyArray<string>).includes(shell),
  );
}

function unwrapCommandRemainder(value: string, wrapperFlagPattern: RegExp): string | null {
  const match = wrapperFlagPattern.exec(value);
  if (!match) {
    return null;
  }

  const command = value.slice(match.index + match[0].length).trim();
  if (command.length === 0) {
    return null;
  }

  const openingQuote = command[0];
  if ((openingQuote === "'" || openingQuote === '"') && !command.endsWith(openingQuote)) {
    return null;
  }

  const unwrapped = trimMatchingOuterQuotes(command);
  return unwrapped.length > 0 ? unwrapped : null;
}

function unwrapKnownShellCommandWrapper(value: string): string {
  const split = splitExecutableAndRest(value);
  if (!split || split.rest.length === 0) {
    return value;
  }

  const shell = executableBasename(split.executable);
  if (!shell) {
    return value;
  }

  const spec = findShellWrapperSpec(shell);
  if (!spec) {
    return value;
  }

  return unwrapCommandRemainder(split.rest, spec.wrapperFlagPattern) ?? value;
}

function formatCommandArrayPart(value: string): string {
  return /[\s"'`]/.test(value) ? `"${value.replace(/"/g, '\\"')}"` : value;
}

function formatCommandValue(value: unknown): string | null {
  const direct = asTrimmedString(value);
  if (direct) {
    return direct;
  }
  if (!Array.isArray(value)) {
    return null;
  }
  const parts: Array<string> = [];
  for (const entry of value) {
    const part = asTrimmedString(entry);
    if (part !== null) {
      parts.push(part);
    }
  }
  if (parts.length === 0) {
    return null;
  }
  return parts.map((part) => formatCommandArrayPart(part)).join(" ");
}

function normalizeCommandValue(value: unknown): string | null {
  const formatted = formatCommandValue(value);
  return formatted ? unwrapKnownShellCommandWrapper(formatted) : null;
}

function toRawToolCommand(value: unknown, normalizedCommand: string | null): string | null {
  const formatted = formatCommandValue(value);
  if (!formatted || normalizedCommand === null) {
    return null;
  }
  return formatted === normalizedCommand ? null : formatted;
}

function extractToolCommand(payload: Record<string, unknown> | null): {
  command: string | null;
  rawCommand: string | null;
} {
  const data = asRecord(payload?.data);
  const item = asRecord(data?.item);
  const itemResult = asRecord(item?.result);
  const itemInput = asRecord(item?.input);
  const itemType = asTrimmedString(payload?.itemType);
  const detail = asTrimmedString(payload?.detail);
  const candidates: unknown[] = [
    item?.command,
    itemInput?.command,
    itemResult?.command,
    data?.command,
    itemType === "command_execution" && detail ? stripTrailingExitCode(detail).output : null,
  ];

  for (const candidate of candidates) {
    const command = normalizeCommandValue(candidate);
    if (!command) {
=======
    if (item.type === "proposed_plan") {
      const plan = planById.get(item.planId);
      const proposedPlan = {
        id: item.planId,
        runId: item.runId,
        planMarkdown: item.markdown,
        status: plan?.kind === "proposed_plan" ? plan.status : ("active" as const),
        createdAt,
        updatedAt: DateTime.formatIso(item.updatedAt),
      };
      entries.push({
        id: item.id,
        kind: "proposed-plan",
        createdAt,
        proposedPlan,
        ...attemptMetadata,
      });
>>>>>>> upstream-sync-e8545b293-upstream-renamed
      continue;
    }

    if (STANDALONE_V2_ITEM_TYPES.has(item.type)) {
      entries.push({
        id: item.id,
        kind: "event",
        createdAt,
        projectedItem: row,
        ...attemptMetadata,
      });
      continue;
    }

    entries.push({
      id: item.id,
      kind: "work",
      createdAt,
      entry: projectedWorkEntry(row),
      ...attemptMetadata,
    });
  }

  const retainedMessageIds = new Set([...committedMessageIds, ...foldedAnswerMessageIds]);
  for (const message of input.anchoredMessages ?? []) {
    if (retainedMessageIds.has(message.id)) continue;
    retainedMessageIds.add(message.id);
    const entry: TimelineEntry = {
      id: message.id,
      kind: "message",
      createdAt: message.createdAt,
      message,
    };
    const insertionIndex = entries.findIndex(
      (candidate) => candidate.createdAt > message.createdAt,
    );
    if (insertionIndex === -1) {
      entries.push(entry);
    } else {
      entries.splice(insertionIndex, 0, entry);
    }
  }

  for (const message of input.optimisticMessages) {
    if (message.inputIntent !== "queued_turn" && !retainedMessageIds.has(message.id)) {
      retainedMessageIds.add(message.id);
      entries.push({
        id: message.id,
        kind: "message",
        createdAt: message.createdAt,
        message,
      });
    }
  }

  return entries;
}

type AttachmentResource = Extract<AssetResource, { readonly _tag: "attachment" }>;
const EMPTY_IMAGE_RESOURCES = Object.freeze<ReadonlyArray<AttachmentResource>>([]);

/** A mounted row requests its stored images. Local previews keep their existing URLs. */
export function selectMessageImageResources(
  attachments: ChatMessage["attachments"],
): ReadonlyArray<AttachmentResource> {
  const attachmentIds = new Set<string>();
  for (const attachment of attachments ?? []) {
    if (!isImageAttachment(attachment)) continue;
    const previewUrl = attachment.previewUrl;
    if (previewUrl?.startsWith("blob:") || previewUrl?.startsWith("data:")) continue;
    attachmentIds.add(attachment.id);
  }
  return attachmentIds.size === 0
    ? EMPTY_IMAGE_RESOURCES
    : Array.from(attachmentIds, (attachmentId) => ({ _tag: "attachment", attachmentId }));
}

/** Handoffs need server URLs even while their message rows are unmounted. */
export function selectHandoffImageResources(
  messages: ReadonlyArray<Pick<ChatMessage, "id" | "role" | "attachments">> | undefined,
  handoffs: Readonly<Record<string, ReadonlyArray<string>>>,
): ReadonlyArray<AttachmentResource> {
  if (Object.keys(handoffs).length === 0) return EMPTY_IMAGE_RESOURCES;
  const attachmentIds = new Set<string>();
  for (const message of messages ?? []) {
    if (message.role !== "user" || !handoffs[message.id]?.length) continue;
    for (const attachment of message.attachments ?? []) {
      if (isImageAttachment(attachment)) attachmentIds.add(attachment.id);
    }
  }
  return attachmentIds.size === 0
    ? EMPTY_IMAGE_RESOURCES
    : Array.from(attachmentIds, (attachmentId) => ({ _tag: "attachment", attachmentId }));
}

/** Own one mapper per preview stage. Immutable messages retain unchanged preview objects. */
export function createMessageAttachmentPreviewProjector() {
  const attachmentsBySource = new WeakMap<
    ReadonlyArray<ChatAttachment>,
    ReadonlyArray<ChatAttachment>
  >();
  const messagesBySource = new WeakMap<ChatMessage, ChatMessage>();
  return (
    message: ChatMessage,
    previewUrlFor: (attachment: ChatAttachment) => string | undefined,
  ): ChatMessage => {
    const source = message.attachments;
    if (!source || source.length === 0) return message;
    const previous = attachmentsBySource.get(source) ?? source;
    let changed: ChatAttachment[] | undefined;
    let hasOverrides = false;
    for (const [index, attachment] of source.entries()) {
      const previewUrl = previewUrlFor(attachment);
      const sourceUrl = "previewUrl" in attachment ? attachment.previewUrl : undefined;
      const previousAttachment = previous[index]!;
      const previousUrl =
        "previewUrl" in previousAttachment ? previousAttachment.previewUrl : undefined;
      const next =
        !previewUrl || previewUrl === sourceUrl
          ? attachment
          : previewUrl === previousUrl
            ? previousAttachment
            : { ...attachment, previewUrl };
      hasOverrides ||= next !== attachment;
      if (next !== previousAttachment) {
        changed ??= previous.slice();
        changed[index] = next;
      }
    }
    const attachments = hasOverrides ? (changed ?? previous) : source;
    attachmentsBySource.set(source, attachments);
    if (attachments === source) {
      messagesBySource.delete(message);
      return message;
    }
    const previousMessage = messagesBySource.get(message);
    if (previousMessage?.attachments === attachments) return previousMessage;
    const result = { ...message, attachments };
    messagesBySource.set(message, result);
    return result;
  };
}

/** Text and update time do not change a streaming assistant message's row structure. */
export function isStreamingMessageTextUpdate(previous: ChatMessage, next: ChatMessage): boolean {
  if (
    previous.role !== "assistant" ||
    next.role !== "assistant" ||
    !previous.streaming ||
    !next.streaming
  ) {
    return false;
  }
  const { text: _previousText, updatedAt: _previousUpdatedAt, ...previousMetadata } = previous;
  const { text: _nextText, updatedAt: _nextUpdatedAt, ...nextMetadata } = next;
  return shallow(previousMetadata, nextMetadata);
}

/** Keep provenance and execution metadata in the rebuild boundary, including inspector data. */
export function isStreamingTurnItemTextUpdate(
  previous: OrchestrationV2ProjectedTurnItem,
  next: OrchestrationV2ProjectedTurnItem,
): boolean {
  const { item: previousItem, ...previousSource } = previous;
  const { item: nextItem, ...nextSource } = next;
  if (
    previousItem.type !== "assistant_message" ||
    nextItem.type !== "assistant_message" ||
    !previousItem.streaming ||
    !nextItem.streaming ||
    !shallow(previousSource, nextSource) ||
    projectedItemCreatedAt(previous) !== projectedItemCreatedAt(next)
  ) {
    return false;
  }
  const { text: _previousText, updatedAt: _previousUpdatedAt, ...previousMetadata } = previousItem;
  const { text: _nextText, updatedAt: _nextUpdatedAt, ...nextMetadata } = nextItem;
  // Wire decoding can recreate timestamps and attachments on each update.
  // Compare only the changed item's metadata, never the entire transcript.
  return Equal.equals(previousMetadata, nextMetadata);
}

function reuseTimelineEntries(
  input: TimelineEntriesInput,
  previous: TimelineEntriesProjection,
): TimelineEntry[] | null {
  const before = previous.input;
  if (
    input.visibleTurnItems.length < before.visibleTurnItems.length ||
    !shallow(input.optimisticMessages, before.optimisticMessages) ||
    !shallow(input.anchoredMessages, before.anchoredMessages) ||
    !shallow(input.attachmentUrlById, before.attachmentUrlById) ||
    !shallow(input.attempts, before.attempts) ||
    !shallow(input.nodes, before.nodes) ||
    !shallow(input.plans, before.plans)
  ) {
    return null;
  }
  const appended = input.visibleTurnItems.length > before.visibleTurnItems.length;
  // Anchored and optimistic messages need to be interleaved/deduplicated when
  // committed items arrive. Keep the full projection for that transition.
  if (
    appended &&
    (input.optimisticMessages.length > 0 || (input.anchoredMessages?.length ?? 0) > 0)
  ) {
    return null;
  }
  // Answer rows can replace a message already present in the retained prefix.
  if (
    appended &&
    input.visibleTurnItems
      .slice(before.visibleTurnItems.length)
      .some(
        ({ item }) =>
          (item.type === "user_input_request" && item.questionAnswer !== undefined) ||
          (item.type === "user_message" && item.messageId.startsWith("async-answer:")),
      )
  )
    return null;
  const replacements = new Map<
    OrchestrationV2ProjectedTurnItem,
    OrchestrationV2ProjectedTurnItem
  >();
  for (const [index, previousItem] of before.visibleTurnItems.entries()) {
    const item = input.visibleTurnItems[index]!;
    if (item === previousItem) continue;
    if (!isStreamingTurnItemTextUpdate(previousItem, item)) return null;
    replacements.set(previousItem, item);
  }
  if (replacements.size === 0 && !appended) return previous.entries;
  const entries = previous.entries.map((entry): TimelineEntry => {
    const row =
      entry.kind === "message" && entry.projectedItem !== undefined
        ? replacements.get(entry.projectedItem)
        : undefined;
    if (entry.kind !== "message" || row?.item.type !== "assistant_message") return entry;
    return {
      ...entry,
      projectedItem: row,
      message: {
        ...entry.message,
        text: row.item.text,
        updatedAt: DateTime.formatIso(row.item.updatedAt),
      },
    };
  });
  if (appended) {
    entries.push(
      ...deriveTimelineEntriesFromVisibleTurnItems({
        ...input,
        visibleTurnItems: input.visibleTurnItems.slice(before.visibleTurnItems.length),
      }),
    );
  }
  return entries;
}

/** Reuse immutable entries during streaming without reordering the canonical v2 sequence. */
export function deriveTimelineEntriesFromVisibleTurnItemsWithState(
  input: TimelineEntriesInput,
  previous: TimelineEntriesProjection | null = null,
): TimelineEntriesProjection {
  const reused = previous === null ? null : reuseTimelineEntries(input, previous);
  if (reused !== null) return { input, entries: reused };
  const entries = deriveTimelineEntriesFromVisibleTurnItems(input);
  if (previous === null || !shallow(input.attachmentUrlById, previous.input.attachmentUrlById)) {
    return { input, entries };
  }
  // Tool output and lifecycle changes rebuild grouping, but unchanged message
  // objects and previews still let memoized history rows stay mounted.
  const previousMessages = new Map(
    previous.entries.flatMap((entry) =>
      entry.kind === "message" ? [[entry.id, entry] as const] : [],
    ),
  );
  return {
    input,
    entries: entries.map((entry) => {
      if (entry.kind !== "message" || entry.projectedItem === undefined) return entry;
      const before = previousMessages.get(entry.id);
      if (before?.projectedItem !== entry.projectedItem) return entry;
      return before.attempt === entry.attempt ? before : { ...entry, message: before.message };
    }),
  };
}

export function inferCheckpointTurnCountByRunId(
  summaries: ReadonlyArray<ThreadCheckpointSummary>,
): Record<string, number> {
  return Object.fromEntries(
    summaries.flatMap((summary) =>
      summary.runId === null ? [] : [[summary.runId, summary.checkpointTurnCount] as const],
    ),
  );
}

export function deriveRevertTurnCountByUserMessageId(input: {
  readonly timelineEntries: ReadonlyArray<TimelineEntry>;
  readonly checkpoints: ReadonlyArray<ThreadCheckpointSummary>;
}): Map<ChatMessage["id"], number> {
  const readyCheckpointByRunId = new Map<RunId, ThreadCheckpointSummary>();
  for (const checkpoint of input.checkpoints) {
    if (checkpoint.status === "ready") {
      readyCheckpointByRunId.set(checkpoint.runId, checkpoint);
    }
  }
  const byUserMessageId = new Map<ChatMessage["id"], number>();
  for (const entry of input.timelineEntries) {
    if (entry.kind !== "message" || entry.message.role !== "user") continue;
    if (entry.message.inputIntent !== "turn_start" && entry.message.inputIntent !== "queued_turn") {
      continue;
    }
    if (entry.message.runId === null) continue;
    const checkpoint = readyCheckpointByRunId.get(entry.message.runId);
    if (checkpoint === undefined) continue;
    byUserMessageId.set(entry.message.id, Math.max(0, checkpoint.checkpointTurnCount - 1));
  }
  return byUserMessageId;
}

export function derivePhase(runtime: ThreadRuntimeSummary | null): SessionPhase {
  if (runtime === null) return "disconnected";
  if (
    runtime.status === "preparing" ||
    runtime.status === "starting" ||
    runtime.status === "queued"
  )
    return "connecting";
  if (runtime.status === "running" || runtime.status === "waiting") return "running";
  return "ready";
}

/**
 * Whether web and desktop offer Stop for the active thread. The server settles
 * a preparing or starting run on `run.interrupt` (Orchestrator.dispatchRunInterrupt),
 * so Stop must not wait for the phase to reach "running". A queued thread offers
 * Stop only while an earlier run is still interruptible; Stop targets that run.
 */
export function deriveCanInterruptRunningThread(
  hasActiveThread: boolean,
  runtime: ThreadRuntimeSummary | null,
): boolean {
  return (
    hasActiveThread &&
    (derivePhase(runtime) === "running" || threadRuntimeHasInterruptibleRun(runtime))
  );
}

export type { TurnDiffSummary };
