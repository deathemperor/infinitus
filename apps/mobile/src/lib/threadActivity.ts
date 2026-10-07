import type {
  ThreadPendingApproval,
  ThreadPendingUserInput,
  ThreadUserInputQuestion,
} from "@infinitus/client-runtime/state/thread-requests";
import { turnItemIsWorkspacePreparation } from "@infinitus/client-runtime/state/turn-item-presentation";
import { formatSubagentDisplayTitle } from "@infinitus/client-runtime/state/subagent-display";
import { extractToolActivityPresentation } from "@infinitus/client-runtime/work-log/tool-presentation";
import {
  turnItemHasDetail,
  turnItemNeedsDetailFetch,
} from "@infinitus/client-runtime/work-log/item-detail";
import {
  commandDisplayText,
  commandProgramName,
} from "@infinitus/client-runtime/work-log/command-label";
import {
  contextCompactionLabel,
  toolItemForDisplay,
  workEntryDisplayIndicatesToolFailure,
  liveActivityToolStatus,
  toolGroupAction,
  resolveWorkEntryToolPresentation,
  summarizeToolGroup,
  toolGroupSummaryKind,
  type ToolGroupSummaryKind,
  type WorkLogPresentationEntry,
  type WorkLogToolLifecycleStatus,
} from "@infinitus/client-runtime/work-log/presentation";
import {
  resolveT3McpToolDefinition,
  resolveT3McpToolPresentation,
  type T3McpToolLogo,
  type T3McpToolPresentation,
} from "@infinitus/shared/t3McpToolPresentation";
import type {
  ChatAttachment,
  MessageId,
  OrchestrationV2Actor,
  OrchestrationV2CreationSource,
  OrchestrationV2ExecutionNode,
  OrchestrationMessageContext,
  OrchestrationV2ProjectedTurnItem,
  OrchestrationV2RunAttempt,
  OrchestrationV2RunStatus,
  OrchestrationV2TurnItem,
  OrchestrationV2UserMessageInputIntent,
  RunAttemptId,
  ScheduledTaskId,
} from "@infinitus/contracts";
import { RunId, ThreadId } from "@infinitus/contracts";
import {
  classifyToolActivity,
  collectToolFilePaths,
  dynamicToolTitle,
  formatReadToolLabel,
  formatSearchToolLabel,
} from "@infinitus/shared/toolActivity";
import { formatDuration } from "@infinitus/shared/orchestrationTiming";
import type { HtmlRenderReference } from "@infinitus/shared/htmlRender";
import { compactDynamicToolOutput, htmlRenderFromToolItem } from "@infinitus/shared/toolOutput";
import * as DateTime from "effect/DateTime";

export type PendingApproval = ThreadPendingApproval;
export type PendingUserInput = ThreadPendingUserInput;

export interface PendingUserInputDraftAnswer {
  readonly selectedOptionValues?: ReadonlyArray<string>;
  readonly customAnswer?: string;
  readonly attachmentCount?: number;
  readonly attachmentsBlocked?: boolean;
}

export interface ThreadFeedActivity {
  readonly id: string;
  readonly createdAt: string;
  readonly runId: RunId | null;
  readonly attemptId: RunAttemptId | null;
  readonly summary: string;
  readonly detail: string | null;
  readonly canExpand: boolean;
  /** Expanding fetches the withheld input and output with getTurnItem. */
  readonly fetchesDetail: boolean;
  readonly getFullDetail: () => string | null;
  readonly getCopyText: () => string;
  readonly icon:
    | "agent"
    | "alert"
    | "browser"
    | "computer"
    | "check"
    | "command"
    | "edit"
    | "eye"
    | "globe"
    | "search"
    | "hammer"
    | "lock"
    | "message"
    | "warning"
    | "wrench"
    | "zap";
  readonly logo: T3McpToolLogo | null;
  readonly toolLike: boolean;
  readonly prominent: boolean;
  readonly status: "success" | "failure" | "neutral" | null;
  readonly lifecycleStatus: WorkLogToolLifecycleStatus;
  readonly workEntry: WorkLogPresentationEntry;
  readonly groupedToolDetail?: boolean;
  readonly live?: boolean;
  readonly projectedItem: OrchestrationV2ProjectedTurnItem;
}

<<<<<<< HEAD
export interface WorkLogEntry {
  readonly questionAnswer?: UserInputAttachmentAnswerPayload;
  id: string;
  createdAt: string;
  turnId: TurnId | null;
  label: string;
  detail?: string;
  viewedImagePath?: string;
  command?: string;
  rawCommand?: string;
  /** The agent's one-line description of a Bash call; the row's headline when present (#1231). */
  commandDescription?: string;
  changedFiles?: ReadonlyArray<string>;
  tone: "thinking" | "tool" | "info" | "error";
  toolTitle?: string;
  toolSurface?: import("@infinitus/contracts").ToolActivitySurface;
  toolIcon?: import("@infinitus/contracts").ToolActivityIcon;
  toolSource?: import("@infinitus/contracts").ToolActivitySource;
  itemType?: ToolLifecycleItemType;
  requestKind?: PendingApproval["requestKind"];
  toolLifecycleStatus?: WorkLogToolLifecycleStatus;
  sourceActivityKind?: OrchestrationThreadActivity["kind"];
  toolCallId?: string;
  /**
   * One row per workflow run or per-turn batch of direct spawns, like web's
   * "Kicked off N subagents" CTA. Mobile has no Agents sheet, so the row
   * also carries each agent's terminal state to derive its status label.
   */
  agentSpawn?: {
    readonly workflowId: string | null;
    readonly agentTaskIds: ReadonlyArray<string>;
    readonly agents: ReadonlyArray<{
      readonly title: string;
      readonly status: WorkLogToolLifecycleStatus | undefined;
      readonly detail: string | undefined;
      /** When this member last reported, so the card can show the newest activity. */
      readonly updatedAt: string;
      /** The brief the agent was launched with, from its start row (#1567). */
      readonly prompt?: string;
      /** The agent's newest own tool call, re-homed from the hidden attributed rows (#1567). */
      readonly lastTool?: AgentSpawnMemberTool;
    }>;
  };
  toolData?: unknown;
}

export interface AgentSpawnMemberTool {
  readonly label: string;
  readonly status: WorkLogToolLifecycleStatus | undefined;
  readonly updatedAt: string;
}

interface DerivedWorkLogEntry extends WorkLogEntry {
  sourceActivityKind: OrchestrationThreadActivity["kind"];
  collapseKey?: string;
  /** Grouping key for subagent lifecycle rows (one row per agent). */
  taskId?: string;
  /** The launch brief on an agent's start row (#1567). */
  agentPrompt?: string;
  /** The tool call that launched this agent, when the provider reports one. */
  agentSpawnToolCallId?: string;
  isWorkflowCoordinator?: boolean;
  /** Shell/monitor/plan tasks: ordinary work-log rows, never spawn batches. */
  isBackgroundTask?: boolean;
=======
export interface ThreadFeedMessage {
  readonly context?: import("@infinitus/contracts").OrchestrationMessageContext | undefined;
  readonly id: MessageId;
  readonly role: "user" | "assistant";
  readonly text: string;
  readonly attachments: ReadonlyArray<ChatAttachment>;
  readonly runId: RunId | null;
  readonly streaming: boolean;
  readonly inputIntent?: OrchestrationV2UserMessageInputIntent;
  readonly createdBy?: OrchestrationV2Actor;
  readonly creationSource?: OrchestrationV2CreationSource;
  readonly scheduledTaskId?: ScheduledTaskId;
  readonly senderThreadId?: ThreadId;
  readonly visibility: OrchestrationV2ProjectedTurnItem["visibility"];
  readonly sourceThreadId: ThreadId;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly projectedItem?: OrchestrationV2ProjectedTurnItem;
}

/** A message shown before the server has it: a pending creation or local feedback. */
export interface LocalThreadMessage {
  readonly id: MessageId;
  readonly role: string;
  readonly text: string;
  readonly context?: OrchestrationMessageContext | undefined;
  readonly attachments?: ReadonlyArray<ChatAttachment> | undefined;
  readonly streaming: boolean;
  readonly createdAt: string;
  readonly updatedAt: string;
>>>>>>> upstream-sync-079e4bccd-upstream-renamed
}

type RawThreadFeedEntry =
  | {
      readonly type: "message";
      readonly id: string;
      readonly createdAt: string;
      readonly message: ThreadFeedMessage;
    }
  | {
      readonly type: "activity";
      readonly id: string;
      readonly createdAt: string;
      readonly runId: RunId | null;
      readonly activity: ThreadFeedActivity;
    }
  | {
      /** A page a completed `html_render` call published, shown in place of its work row. */
      readonly type: "html-render";
      readonly id: string;
      readonly createdAt: string;
      readonly runId: RunId | null;
      readonly render: HtmlRenderReference;
    };

export type ThreadFeedEntry = ThreadFeedEntryContent & { readonly continuesWorkLog?: boolean };

type ThreadFeedEntryContent =
  | Extract<RawThreadFeedEntry, { type: "message" | "html-render" }>
  | {
      readonly type: "activity-group";
      readonly id: string;
      readonly createdAt: string;
      readonly runId: RunId | null;
      readonly activities: ReadonlyArray<ThreadFeedActivity>;
    }
  | {
      readonly type: "work-toggle";
      readonly id: string;
      readonly createdAt: string;
      readonly runId: RunId | null;
      readonly groupId: string;
      readonly hiddenCount: number;
      readonly expanded: boolean;
      readonly summary: string;
      readonly summaryKind: ToolGroupSummaryKind;
      readonly toolSurface?: WorkLogPresentationEntry["toolSurface"];
      readonly toolIcon?: WorkLogPresentationEntry["toolIcon"];
      readonly summaryToolIcon?: "browser" | "device" | "t3-code" | "pull-request";
      readonly hasFailure: boolean;
      readonly live: boolean;
      readonly shimmer: boolean;
    }
  | {
      readonly type: "run-fold";
      readonly id: string;
      readonly createdAt: string;
      readonly runId: RunId;
      readonly label: string;
      readonly expanded: boolean;
    }
  | {
      readonly type: "thinking";
      readonly id: string;
      readonly createdAt: string;
      readonly runId: RunId | null;
    };

export interface ThreadFeedLatestRun {
  readonly runId: RunId;
  readonly status: OrchestrationV2RunStatus;
  readonly startedAt: string | null;
  readonly completedAt: string | null;
}

export interface AgentSpawnSummary {
  readonly title: string;
  readonly status: string;
  readonly tone: "working" | "completed" | "failed" | "stopped";
  readonly members: ReadonlyArray<{
    readonly title: string;
    readonly status: string;
    readonly tone: "working" | "completed" | "failed" | "stopped";
    readonly detail: string | undefined;
    readonly updatedAt: string;
    readonly prompt?: string;
  }>;
}

function compactWorkEntryText(value: string): string {
  return value.replace(/\s+/gu, " ").trim();
}

/** Expanded work rows keep their detail while compact rows show a stable one-line label. */
export function workEntryRowLabel(entry: WorkLogPresentationEntry, expanded = false): string {
  if (expanded && entry.itemType === "reasoning")
    return entry.toolLifecycleStatus === "inProgress" ? "Thinking" : "Thought";
  const presentation = resolveWorkEntryToolPresentation(entry);
  if (presentation) return presentation.displayName;
  if (entry.command?.trim()) return compactWorkEntryText(commandDisplayText(entry.command));
  const action = toolGroupAction(entry);
  const isToolRead = action === "read" && entry.itemType === "dynamic_tool";
  if (action === "code-search" || action === "search") {
    const toolData =
      entry.toolData !== null &&
      typeof entry.toolData === "object" &&
      !Array.isArray(entry.toolData)
        ? (entry.toolData as Record<string, unknown>)
        : undefined;
    // Adapters title file searches with their target; the item keeps only the pattern.
    const searchLabel =
      entry.itemType === "file_search" ? entry.label : formatSearchToolLabel(toolData);
    if (searchLabel) return searchLabel;
  }
  if (isToolRead) {
    const [firstPath] = entry.changedFiles ?? collectToolFilePaths(entry.toolData);
    if (firstPath) {
      return formatReadToolLabel(firstPath, Math.max(0, (entry.changedFiles?.length ?? 1) - 1));
    }
    if (!expanded) return "Read file";
  }
  const preview =
    entry.command ??
    (isToolRead || (!expanded && (action === "code-search" || action === "search"))
      ? null
      : entry.detail) ??
    (entry.changedFiles?.length
      ? entry.changedFiles.length === 1
        ? entry.changedFiles[0]!
        : `${entry.changedFiles[0]!} +${entry.changedFiles.length - 1} more`
      : null);
  if (expanded) return preview?.trim() || entry.label;
  return preview ? compactWorkEntryText(preview) || entry.label : entry.label;
}

type ThreadFeedActivityGroup = Extract<ThreadFeedEntry, { readonly type: "activity-group" }>;

// Immutable source rows let retained history keep its identities while the active item streams.
const projectedEntriesCache = new WeakMap<
  OrchestrationV2ProjectedTurnItem,
  {
    readonly attemptId: RunAttemptId | null;
    readonly entry: RawThreadFeedEntry;
  }
>();
const localMessageEntriesCache = new WeakMap<
  LocalThreadMessage,
  Extract<RawThreadFeedEntry, { readonly type: "message" }>
>();
const activityGroupsCache = new WeakMap<ThreadFeedActivity, ThreadFeedActivityGroup>();
const failedActivityGroupsCache = new WeakMap<
  ThreadFeedActivityGroup,
  ReadonlyArray<ThreadFeedActivityGroup>
>();
const presentedActivityGroupsCache = new WeakMap<
  ThreadFeedActivityGroup,
  {
    readonly activeRunId: RunId | null;
    readonly isWorking: boolean;
    readonly activeTail: boolean;
    readonly rows: ReadonlyArray<ThreadFeedEntry>;
  }
>();
const runFoldRowsCache = new WeakMap<
  ThreadFeedEntry,
  Extract<ThreadFeedEntry, { readonly type: "run-fold" }>
>();
let cachedThinkingRow: Extract<ThreadFeedEntry, { readonly type: "thinking" }> | null = null;

export function isContextCompactionActivityGroup(entry: ThreadFeedActivityGroup): boolean {
  return (
    entry.activities.length === 1 && entry.activities[0]?.projectedItem.item.type === "compaction"
  );
}

export function isContextHandoffActivityGroup(entry: ThreadFeedActivityGroup): boolean {
  return (
    entry.activities.length === 1 && entry.activities[0]?.projectedItem.item.type === "handoff"
  );
}

export function isSecretRequestActivityGroup(entry: ThreadFeedActivityGroup): boolean {
  return (
    entry.activities.length === 1 &&
    entry.activities[0]?.projectedItem.item.type === "secret_request"
  );
}

function isUserInputActivityGroup(entry: ThreadFeedActivityGroup): boolean {
  return entry.activities.some((activity) => activity.workEntry.questionAnswer !== undefined);
}

function normalizeDraftAnswer(value: string | undefined): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function resolvePendingUserInputOptionValue(
  question: ThreadUserInputQuestion,
  value: string,
): string | null {
  if (question.options.some((option) => option.value === value)) {
    return value;
  }

  const label = value.trim();
  return label.length > 0 &&
    question.options.some((option) => option.value === undefined && option.label.trim() === label)
    ? label
    : null;
}

function normalizeSelectedOptionValues(
  question: ThreadUserInputQuestion,
  value: ReadonlyArray<string> | undefined,
): ReadonlyArray<string> {
  if (!Array.isArray(value)) {
    return [];
  }

  return Array.from(
    new Set(
      value
        .map((entry) => resolvePendingUserInputOptionValue(question, entry))
        .filter((entry): entry is string => entry !== null),
    ),
  );
}

function resolvePendingUserInputAnswer(
  question: ThreadUserInputQuestion,
  draft: PendingUserInputDraftAnswer | undefined,
): string | ReadonlyArray<string> | null {
  if (draft?.attachmentsBlocked) return null;
  const customAnswer =
    question.allowCustomAnswer === false ? null : normalizeDraftAnswer(draft?.customAnswer);
  if (customAnswer) {
    return customAnswer;
  }

  const selectedOptionValues = normalizeSelectedOptionValues(question, draft?.selectedOptionValues);
  if (question.multiSelect) {
    return selectedOptionValues.length > 0
      ? selectedOptionValues
      : question.allowCustomAnswer !== false && (draft?.attachmentCount ?? 0) > 0
        ? ""
        : null;
  }
  return (
    selectedOptionValues[0] ??
    (question.allowCustomAnswer !== false && (draft?.attachmentCount ?? 0) > 0 ? "" : null)
  );
}

<<<<<<< HEAD
/** Some providers settle agents through task.updated instead of task.completed. */
const MOBILE_TERMINAL_UPDATE_STATUSES: ReadonlySet<string> = new Set([
  "completed",
  "failed",
  "cancelled",
  "interrupted",
]);

function isTerminalTaskUpdate(activity: OrchestrationThreadActivity): boolean {
  if (activity.kind !== "task.updated") {
    return false;
  }
  const payload =
    activity.payload && typeof activity.payload === "object"
      ? (activity.payload as Record<string, unknown>)
      : null;
  return (
    typeof payload?.status === "string" &&
    (MOBILE_TERMINAL_UPDATE_STATUSES.has(payload.status) ||
      (payload.timelineBypass === true && payload.status === "idle"))
  );
}

/**
 * Quiet-timeline guarantee (mirrors web's session-logic): agent-internal
 * activity lives in the Agents sheet, not the work log. Agent lifecycle rows
 * pass even when bypassed or owned by another agent, because they fold into
 * their spawn batch rather than rendering on their own; that is how Codex
 * children (all bypassed) and Claude workflow members reach the batch row.
 * Terminal rows are kept regardless — with no Agents surface on mobile they
 * are the terminal signal.
 */
function isAgentInternalActivity(activity: OrchestrationThreadActivity): boolean {
  const payload =
    activity.payload && typeof activity.payload === "object"
      ? (activity.payload as Record<string, unknown>)
      : null;
  if (!payload) {
    return false;
  }
  const isTaskRow =
    activity.kind === "task.started" ||
    activity.kind === "task.progress" ||
    activity.kind === "task.updated" ||
    activity.kind === "task.completed";
  const ownedByAgent = typeof payload.agentId === "string" && payload.agentId.trim().length > 0;
  if (isTaskRow) {
    if (!ownedByAgent && payload.timelineBypass !== true) {
      return false;
    }
    // An agent's own shells stay internal; the agents themselves fold into
    // their batch. A bypassed batch marker keeps its terminal row.
    if (typeof payload.taskId === "string" && payload.agentKind === "agent") {
      return false;
    }
    if (ownedByAgent) {
      return true;
    }
    return !(activity.kind === "task.completed" || isTerminalTaskUpdate(activity));
  }
  return payload.timelineBypass === true || ownedByAgent;
}

/** Agent (non-background) task.started rows seed spawn batches. */
function isAgentTaskStartedActivity(activity: OrchestrationThreadActivity): boolean {
  const payload =
    activity.payload && typeof activity.payload === "object"
      ? (activity.payload as Record<string, unknown>)
      : null;
  return typeof payload?.taskId === "string" && payload.agentKind === "agent";
}

function deriveWorkLogEntries(
  activities: ReadonlyArray<OrchestrationThreadActivity>,
): DerivedWorkLogEntry[] {
  const ordered = Arr.sort(activities, activityOrder);
  const entries: DerivedWorkLogEntry[] = [];
  for (const activity of foldUserInputActivities(ordered)) {
    // The setup card owns its snapshot, including failed and cancelled outcomes.
    if (
      isWorktreeSetupActivity(activity.kind) &&
      (activity.tone !== "error" || activity.kind === "worktree-setup")
    )
      continue;
    if (activity.kind === "tool.started") continue;
    // Like web: an agent's task.started row anchors its batch. It has a fixed
    // id and timestamp, unlike progress ticks, whose stable per-task id is
    // rewritten with a new createdAt on every update (and would otherwise
    // make the batch row a "fresh" row again on each tick).
    if (activity.kind === "task.started" && !isAgentTaskStartedActivity(activity)) continue;
    if (activity.kind === "task.updated" && !isTerminalTaskUpdate(activity)) continue;
    if (activity.kind === "tool.progress") continue;
    if (activity.kind === "context-window.updated") continue;
    if (activity.summary === "Checkpoint captured") continue;
    if (isNoContentRuntimeWarning(activity)) continue;
    if (isPlanBoundaryToolActivity(activity)) continue;
    if (isAgentInternalActivity(activity)) continue;
    entries.push(toDerivedWorkLogEntry(activity));
  }
  return attachAgentTools(collapseDerivedWorkLogEntries(entries), latestAgentTools(ordered));
}

/**
 * The newest attributed tool row per owning agent (#1567). The quiet
 * timeline hides these rows; the spawn card shows each member's current
 * call instead of a progress line that may be a minute stale.
 */
function latestAgentTools(
  ordered: ReadonlyArray<OrchestrationThreadActivity>,
): ReadonlyMap<string, AgentSpawnMemberTool> {
  // Only the winner per agent is derived into an entry; the rest is a scan.
  const newest = new Map<string, OrchestrationThreadActivity>();
  for (const activity of ordered) {
    if (activity.kind !== "tool.updated" && activity.kind !== "tool.completed") continue;
    const agentId = asTrimmedString(asRecord(activity.payload)?.agentId);
    if (!agentId || isPlanBoundaryToolActivity(activity)) continue;
    newest.set(agentId, activity);
  }
  const latest = new Map<string, AgentSpawnMemberTool>();
  for (const [agentId, activity] of newest) {
    const entry = toDerivedWorkLogEntry(activity);
    latest.set(agentId, {
      label: workEntryHeading(entry),
      status: entry.toolLifecycleStatus,
      updatedAt: activity.createdAt,
    });
  }
  return latest;
}

function attachAgentTools(
  entries: DerivedWorkLogEntry[],
  tools: ReadonlyMap<string, AgentSpawnMemberTool>,
): DerivedWorkLogEntry[] {
  if (tools.size === 0) return entries;
  return entries.map((entry) => {
    const spawn = entry.agentSpawn;
    if (!spawn || !spawn.agentTaskIds.some((taskId) => tools.has(taskId))) return entry;
    const agents = spawn.agents.map((agent, index) => {
      const lastTool = tools.get(spawn.agentTaskIds[index] ?? "");
      return lastTool ? { ...agent, lastTool } : agent;
    });
    return { ...entry, agentSpawn: { ...spawn, agents } };
  });
}

/** Adapters forward unknown wire-only SDK messages (background_tasks_changed,
 *  commands_changed, ...) as runtime warnings. The suffix comes from
 *  describeUnknownSdkMessage in the Claude adapter; a row with no displayable
 *  text carries nothing a user can act on, so it does not render. */
function isNoContentRuntimeWarning(activity: OrchestrationThreadActivity): boolean {
  return (
    activity.kind === "runtime.warning" &&
    activity.summary.endsWith("(no displayable text content)")
  );
}

function isPlanBoundaryToolActivity(activity: OrchestrationThreadActivity): boolean {
  if (activity.kind !== "tool.updated" && activity.kind !== "tool.completed") {
    return false;
  }

  const payload =
    activity.payload && typeof activity.payload === "object"
      ? (activity.payload as Record<string, unknown>)
      : null;
  return typeof payload?.detail === "string" && payload.detail.startsWith("ExitPlanMode:");
}

const decodeQuestionAttachmentAnswer = Schema.decodeUnknownOption(UserInputAttachmentAnswerPayload);

function toDerivedWorkLogEntry(activity: OrchestrationThreadActivity): DerivedWorkLogEntry {
  const payload =
    activity.payload && typeof activity.payload === "object"
      ? (activity.payload as Record<string, unknown>)
      : null;
  const commandPreview = extractToolCommand(payload);
  const changedFiles = extractChangedFiles(payload);
  const title = extractToolTitle(payload);
  const toolPresentation = extractToolActivityPresentation(payload);
  // Terminal task updates carry identity so they replace each child's progress row.
  const isTaskActivity =
    activity.kind === "task.started" ||
    activity.kind === "task.progress" ||
    activity.kind === "task.completed" ||
    activity.kind === "task.updated";
  const taskSummary =
    isTaskActivity && typeof payload?.summary === "string" && payload.summary.length > 0
      ? payload.summary
      : null;
  const taskDetailAsLabel =
    isTaskActivity &&
    !taskSummary &&
    !title &&
    typeof payload?.detail === "string" &&
    payload.detail.length > 0
      ? payload.detail
      : null;
  const taskLabel = taskSummary || taskDetailAsLabel;
  const taskId =
    isTaskActivity && typeof payload?.taskId === "string" && payload.taskId.length > 0
      ? payload.taskId
      : undefined;
  const entry: DerivedWorkLogEntry = {
    id: activity.id,
    createdAt: activity.createdAt,
    turnId: activity.turnId,
    ...(taskId ? { taskId } : {}),
    label: taskLabel || activity.summary,
    tone:
      activity.kind === "task.progress"
        ? "thinking"
        : activity.tone === "approval"
          ? "info"
          : activity.tone,
    sourceActivityKind: activity.kind,
    ...(() => {
      if (activity.kind !== "user-input.answer-submitted") return {};
      const answer = decodeQuestionAttachmentAnswer(activity.payload);
      return Option.isSome(answer) ? { questionAnswer: answer.value } : {};
    })(),
  };
  const toolCallId =
    asTrimmedString(payload?.toolCallId) ?? asTrimmedString(asRecord(payload?.data)?.toolCallId);
  if (toolCallId) {
    entry.toolCallId = toolCallId;
  }
  if (isTaskActivity && payload) {
    if (payload.agentKind !== "agent") {
      entry.isBackgroundTask = true;
    }
    const spawnToolCallId = asTrimmedString(payload.toolUseId);
    if (spawnToolCallId) {
      entry.agentSpawnToolCallId = spawnToolCallId;
    }
    const agentPrompt = asTrimmedString(payload.prompt);
    if (agentPrompt) {
      entry.agentPrompt = agentPrompt;
    }
    if (
      payload.taskType === "local_workflow" ||
      (typeof payload.workflowName === "string" && payload.workflowName.length > 0)
    ) {
      entry.isWorkflowCoordinator = true;
    }
  }
  const itemType = extractWorkLogItemType(payload);
  const requestKind = extractWorkLogRequestKind(payload);
  const viewedImagePath = asTrimmedString(asRecord(payload?.data)?.imagePath);
  const commandOutput = commandPreview.command ? extractCommandOutputText(payload?.data) : null;
  const output = commandOutput ? stripTrailingExitCode(commandOutput).output : null;
  if (!taskDetailAsLabel && output) {
    entry.detail = output;
  } else if (!taskDetailAsLabel && typeof payload?.detail === "string") {
    const detail = stripTrailingExitCode(payload.detail).output;
    const data = asRecord(payload.data);
    const repeatsCommand =
      detail !== null &&
      commandDetailRepeatsCommand({
        detail,
        command: commandPreview.command,
        rawCommand: commandPreview.rawCommand,
        toolName: data?.toolName,
        data,
      });
    if (detail && detail !== title && !repeatsCommand) entry.detail = detail;
  }
  if (isTaskActivity && typeof payload?.error === "string" && payload.error.trim()) {
    entry.detail = payload.error;
  }
  if (!entry.detail && (activity.kind === "runtime.error" || activity.kind === "runtime.warning")) {
    const message = asTrimmedString(payload?.message);
    if (message) entry.detail = message;
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
    entry.commandDescription = collapseWhitespace(commandDescription);
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
    }
  }
  if (itemType) {
    entry.itemType = itemType;
  }
  if (requestKind) {
    entry.requestKind = requestKind;
  }
  let toolLifecycleStatus = extractWorkLogToolLifecycleStatus(payload);
  if (
    !toolLifecycleStatus &&
    (activity.kind === "tool.completed" || activity.kind === "task.completed")
  ) {
    toolLifecycleStatus = activity.tone === "error" ? "failed" : "completed";
  }
  // A Codex child that finishes its turn reports "idle" (resumable, not
  // terminal). For the batch row that is a finished member.
  if (!toolLifecycleStatus && isTaskActivity && payload?.status === "idle") {
    toolLifecycleStatus = "completed";
  }
  if (toolLifecycleStatus) {
    entry.toolLifecycleStatus = toolLifecycleStatus;
  }
  const collapseKey = deriveToolLifecycleCollapseKey(entry);
  if (collapseKey) {
    entry.collapseKey = collapseKey;
  }
  return entry;
}

/**
 * Spawn-group key for a subagent lifecycle row. Workflow members and their
 * coordinator share the coordinator's group; direct spawns batch per turn.
 * Same keys as web's session-logic so both clients fold the same rows.
 */
function agentSpawnGroupKey(entry: DerivedWorkLogEntry): string {
  const taskId = entry.taskId ?? "";
  const workflowSlot = taskId.indexOf(":wf:");
  if (workflowSlot !== -1) return `wf:${taskId.slice(0, workflowSlot)}`;
  if (entry.isWorkflowCoordinator) return `wf:${taskId}`;
  return entry.turnId ? `direct:${entry.turnId}` : `direct:task:${taskId}`;
}

/**
 * The batch row keeps the group's anchor identity (id, createdAt, turnId,
 * label) so it renders where the run launched instead of drifting to the
 * newest progress tick, and gains each member's latest lifecycle state.
 */
function agentSpawnRow(
  anchor: DerivedWorkLogEntry,
  workflowId: string | null,
  agentTaskIds: ReadonlyArray<string>,
  members: NonNullable<WorkLogEntry["agentSpawn"]>["agents"],
): DerivedWorkLogEntry {
  // A finished coordinator settles members that never reported their own
  // end; Claude stops synthesizing member ticks once the workflow is done.
  const coordinator = workflowId === null ? undefined : members[agentTaskIds.indexOf(workflowId)];
  const agents =
    coordinator?.status !== undefined && coordinator.status !== "inProgress"
      ? members.map((agent) =>
          agent.status === undefined || agent.status === "inProgress"
            ? { ...agent, status: coordinator.status }
            : agent,
        )
      : members;
  const agentSpawn = { workflowId, agentTaskIds, agents };
  // The batch row has no detail of its own: its body lists the members.
  const { detail: _detail, ...anchorWithoutDetail } = anchor;
  return {
    ...anchorWithoutDetail,
    // The row's own lifecycle is the batch's: live while any member is, then
    // the worst terminal state, so the group summary and shimmer follow it.
    toolLifecycleStatus: agentSpawnLifecycleStatus(agents),
    agentSpawn,
  };
}

function agentSpawnMember(
  entry: DerivedWorkLogEntry,
  previous?: NonNullable<WorkLogEntry["agentSpawn"]>["agents"][number],
) {
  return {
    title: entry.toolTitle ?? previous?.title ?? entry.label,
    status: entry.toolLifecycleStatus ?? previous?.status,
    detail: entry.detail ?? previous?.detail,
    updatedAt: entry.createdAt,
    ...((entry.agentPrompt ?? previous?.prompt)
      ? { prompt: entry.agentPrompt ?? previous?.prompt }
      : {}),
  };
}

function mergeAgentSpawnEntries(
  existing: DerivedWorkLogEntry,
  entry: DerivedWorkLogEntry,
): DerivedWorkLogEntry {
  const spawn = existing.agentSpawn!;
  const taskId = entry.taskId ?? "";
  const memberIndex = spawn.agentTaskIds.indexOf(taskId);
  if (memberIndex === -1) {
    return agentSpawnRow(
      existing,
      spawn.workflowId,
      [...spawn.agentTaskIds, taskId],
      [...spawn.agents, agentSpawnMember(entry)],
    );
  }
  const agents = spawn.agents.map((agent, index) =>
    index === memberIndex ? agentSpawnMember(entry, agent) : agent,
  );
  return agentSpawnRow(existing, spawn.workflowId, spawn.agentTaskIds, agents);
}

function agentSpawnLifecycleStatus(
  agents: NonNullable<WorkLogEntry["agentSpawn"]>["agents"],
): WorkLogToolLifecycleStatus {
  const statuses = agents.map((agent) => agent.status);
  if (statuses.some((status) => status === undefined || status === "inProgress")) {
    return "inProgress";
  }
  if (statuses.includes("failed")) return "failed";
  if (statuses.includes("declined")) return "declined";
  if (statuses.includes("stopped")) return "stopped";
  return "completed";
}

function collapseDerivedWorkLogEntries(
  entries: ReadonlyArray<DerivedWorkLogEntry>,
): DerivedWorkLogEntry[] {
  const collapsed: DerivedWorkLogEntry[] = [];
  // Task rows collapse by identity, not adjacency (quiet-timeline guarantee;
  // mirrors web's session-logic). Background tasks keep one row per taskId;
  // agent spawns fold into one row per spawn group, decided at the FIRST row
  // seen for a taskId because later rows can arrive under synthetic turns.
  const taskRowIndex = new Map<string, number>();
  const spawnRowIndex = new Map<string, number>();
  const spawnGroupByTaskId = new Map<string, string>();
  const toolLifecycleRowIndex = new Map<string, number>();
  // Tool calls that launched an agent (Claude's Agent tool, ACP subagent
  // calls). The batch card is the whole story of that call, so its own
  // lifecycle row is dropped.
  const spawnToolCallIds = new Set(
    entries.flatMap((entry) =>
      entry.agentSpawnToolCallId !== undefined ? [entry.agentSpawnToolCallId] : [],
    ),
  );
  for (const entry of entries) {
    if (
      entry.toolCallId !== undefined &&
      entry.taskId === undefined &&
      spawnToolCallIds.has(entry.toolCallId)
    ) {
      continue;
    }
    const isTaskRow =
      entry.taskId !== undefined &&
      (entry.sourceActivityKind === "task.started" ||
        entry.sourceActivityKind === "task.progress" ||
        entry.sourceActivityKind === "task.completed" ||
        entry.sourceActivityKind === "task.updated");
    if (isTaskRow && entry.taskId !== undefined) {
      if (entry.isBackgroundTask) {
        const existingIndex = taskRowIndex.get(entry.taskId);
        if (existingIndex !== undefined) {
          collapsed[existingIndex] = mergeDerivedWorkLogEntries(collapsed[existingIndex]!, entry);
          continue;
        }
        taskRowIndex.set(entry.taskId, collapsed.length);
        collapsed.push(entry);
        continue;
      }
      const groupKey = spawnGroupByTaskId.get(entry.taskId) ?? agentSpawnGroupKey(entry);
      spawnGroupByTaskId.set(entry.taskId, groupKey);
      const existingIndex = spawnRowIndex.get(groupKey);
      if (existingIndex !== undefined) {
        collapsed[existingIndex] = mergeAgentSpawnEntries(collapsed[existingIndex]!, entry);
        continue;
      }
      spawnRowIndex.set(groupKey, collapsed.length);
      collapsed.push(
        agentSpawnRow(
          entry,
          groupKey.startsWith("wf:") ? groupKey.slice(3) : null,
          [entry.taskId],
          [agentSpawnMember(entry)],
        ),
      );
      continue;
    }
    const lifecycleKey = toolLifecycleCollapseMapKey(entry);
    if (lifecycleKey !== undefined) {
      const matchingIndex = toolLifecycleRowIndex.get(lifecycleKey);
      const matchingEntry = matchingIndex === undefined ? undefined : collapsed[matchingIndex];
      if (
        matchingIndex !== undefined &&
        matchingEntry &&
        shouldCollapseToolLifecycleEntries(matchingEntry, entry)
      ) {
        collapsed[matchingIndex] = mergeDerivedWorkLogEntries(matchingEntry, entry);
        continue;
      }
      toolLifecycleRowIndex.delete(lifecycleKey);
    }
    const previous = collapsed.at(-1);
    if (previous && shouldCollapseToolLifecycleEntries(previous, entry)) {
      const previousIndex = collapsed.length - 1;
      const previousKey = toolLifecycleCollapseMapKey(previous);
      if (previousKey !== undefined) toolLifecycleRowIndex.delete(previousKey);
      const merged = mergeDerivedWorkLogEntries(previous, entry);
      collapsed[previousIndex] = merged;
      const mergedKey = toolLifecycleCollapseMapKey(merged);
      if (mergedKey !== undefined) toolLifecycleRowIndex.set(mergedKey, previousIndex);
      continue;
    }
    collapsed.push(entry);
    if (lifecycleKey !== undefined) {
      toolLifecycleRowIndex.set(lifecycleKey, collapsed.length - 1);
    }
  }
  return collapsed;
}

function toolLifecycleCollapseMapKey(entry: DerivedWorkLogEntry): string | undefined {
  if (
    entry.sourceActivityKind !== "tool.updated" &&
    entry.sourceActivityKind !== "tool.completed"
  ) {
    return undefined;
  }
  return entry.toolCallId ? `tool:${entry.turnId ?? "no-turn"}:${entry.toolCallId}` : undefined;
}

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
  if (previous.collapseKey !== undefined && previous.collapseKey === next.collapseKey) {
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
  const collapseKey = next.collapseKey ?? previous.collapseKey;
  const toolLifecycleStatus = next.toolLifecycleStatus ?? previous.toolLifecycleStatus;
  const toolCallId = next.toolCallId ?? previous.toolCallId;
  const toolData = next.toolData ?? previous.toolData;
  return {
    ...previous,
    ...next,
    id: previous.id,
    createdAt: previous.createdAt,
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
    ...(collapseKey ? { collapseKey } : {}),
    ...(toolLifecycleStatus ? { toolLifecycleStatus } : {}),
    ...(toolCallId ? { toolCallId } : {}),
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

function workEntryStatus(entry: WorkLogEntry): ThreadFeedActivity["status"] {
  if (entry.agentSpawn) {
    switch (entry.toolLifecycleStatus) {
      case "failed":
        return "failure";
      case "completed":
        return "success";
      default:
        return "neutral";
    }
  }
  if (!workLogEntryIsToolLike(entry)) {
    return null;
  }
  if (workEntryIndicatesToolFailure(entry)) {
    return "failure";
  }
  if (workEntryIndicatesToolSuccess(entry)) {
    return "success";
  }
  return "neutral";
}

function workEntryIcon(entry: DerivedWorkLogEntry): ThreadFeedActivity["icon"] {
  if (entry.agentSpawn) return "agent";
  if (
    entry.questionAnswer ||
    entry.sourceActivityKind === "user-input.requested" ||
    entry.sourceActivityKind === "user-input.resolved"
  ) {
    return "message";
  }
  if (entry.sourceActivityKind === "runtime.warning") return "warning";
  if (entry.toolSurface) return entry.toolSurface;
  if (entry.requestKind === "command") return "command";
  if (entry.requestKind === "file-read") return "eye";
  if (entry.requestKind === "file-change") return "edit";
  if (entry.requestKind === "permission") return "lock";
  if (entry.itemType === "command_execution" || entry.command) return "command";
  if (entry.itemType === "file_change" || (entry.changedFiles?.length ?? 0) > 0) return "edit";
  if (entry.itemType === "web_search") return "globe";
  if (entry.itemType === "image_view") return "eye";
  if (entry.itemType === "mcp_tool_call") return "wrench";
  if (entry.itemType === "dynamic_tool_call" || entry.itemType === "collab_agent_tool_call") {
    return "hammer";
  }
  if (entry.tone === "error") return "alert";
  if (entry.tone === "thinking") return "agent";
  if (entry.tone === "info") return "check";
  return "zap";
}

function buildWorkEntryExpandedBody(entry: WorkLogEntry): string | null {
  if (entry.agentSpawn) return agentSpawnExpandedBody(entry.agentSpawn);
  const blocks: string[] = [];
  const visibleLabel = workEntryRowLabel(entry, true).trim();
  const appendBlock = (value: string | null | undefined) => {
    const trimmed = value?.trim();
    if (trimmed && (entry.command || (trimmed !== visibleLabel && !blocks.includes(trimmed)))) {
      blocks.push(trimmed);
    }
  };

  if (entry.itemType === "mcp_tool_call" && entry.toolData !== undefined) {
    appendBlock(`MCP call\n${JSON.stringify(entry.toolData, null, 2)}`);
  }
  appendBlock(entry.rawCommand ?? entry.command);
  appendBlock(entry.detail);
  if ((entry.changedFiles?.length ?? 0) > 0) {
    appendBlock(entry.changedFiles!.join("\n"));
  }

  return blocks.length > 0 ? blocks.join("\n\n") : null;
}

/**
 * Even single-line details can be truncated by the available screen width.
 * Cheap field checks come first so large tool payloads are not serialized
 * for every row (see the deferred-expansion test).
 */
function workEntryCanExpand(entry: WorkLogEntry): boolean {
  if (entry.questionAnswer) return true;
  if (entry.agentSpawn) return agentSpawnMembers(entry.agentSpawn).length > 0;
  if (entry.itemType === "mcp_tool_call" && entry.toolData !== undefined) return true;
  if (entry.changedFiles?.some((path) => path.trim().length > 0)) return true;
  return Boolean((entry.rawCommand ?? entry.command)?.trim() || entry.detail?.trim());
}

function collapseWhitespace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function stripShellWrapper(value: string): string {
  const trimmed = value.trim();
  const match = trimmed.match(/^\/bin\/zsh -lc ['"]?([\s\S]*?)['"]?$/);
  return (match?.[1] ?? trimmed).trim();
}

/** Expanded rows retain detail formatting; commands stay in the separate body. */
export function workEntryRowLabel(entry: WorkLogEntry, expanded = false): string {
  if (entry.agentSpawn) return agentSpawnLabel(entry.agentSpawn);
  const presentation = resolveWorkEntryToolPresentation(entry);
  if (presentation) return presentation.displayName;
  if (entry.commandDescription) return entry.commandDescription;
  if (expanded && entry.command?.trim()) return "Command";
  const preview = workEntryPreview(entry);
  if (expanded) return preview?.trim() || workEntryHeading(entry);
  const compactPreview = preview === null ? null : collapseWhitespace(stripShellWrapper(preview));
  return compactPreview || workEntryHeading(entry);
=======
function capitalizePhrase(value: string): string {
  const trimmed = value.trim();
  return trimmed.length === 0 ? value : `${trimmed.charAt(0).toUpperCase()}${trimmed.slice(1)}`;
>>>>>>> upstream-sync-079e4bccd-upstream-renamed
}

function memoizeValue<T>(build: () => T): () => T {
  let value: T;
  let initialized = false;
  return () => {
    if (!initialized) {
      value = build();
      initialized = true;
    }
    return value;
  };
}

function itemIsToolLike(item: OrchestrationV2TurnItem): boolean {
  return (
    item.type === "reasoning" ||
    item.type === "command_execution" ||
    item.type === "file_change" ||
    item.type === "file_search" ||
    item.type === "web_search" ||
    item.type === "approval_request" ||
    item.type === "user_input_request" ||
    item.type === "dynamic_tool" ||
    item.type === "subagent"
  );
}

function itemIsProminent(item: OrchestrationV2TurnItem): boolean {
  return (
    item.type === "fork" ||
    item.type === "thread_created" ||
    item.type === "system_notice" ||
    // An answerable card: it must stand alone and never fold away with the run.
    item.type === "secret_request"
  );
}

function itemStatus(item: OrchestrationV2TurnItem): ThreadFeedActivity["status"] {
  if (item.type === "notification") return item.outcome === "failed" ? "failure" : null;
  if (item.type === "error") {
    if (item.status === "failed")
      return item.failure.class === "usage_limit" ? "neutral" : "failure";
    return item.status === "completed" ? "success" : "neutral";
  }
  if (!itemIsToolLike(item)) return null;
  if (item.status === "failed") return "failure";
  return item.status === "completed" ? "success" : "neutral";
}

function itemLifecycleStatus(item: OrchestrationV2TurnItem): WorkLogToolLifecycleStatus {
  switch (item.status) {
    case "pending":
    case "running":
    case "waiting":
      return "inProgress";
    case "idle":
      return "idle";
    case "completed":
      return "completed";
    case "failed":
      return "failed";
    case "cancelled":
    case "interrupted":
      return "stopped";
  }
}

<<<<<<< HEAD
/**
 * What the spawn card shows. While members work, the status line is the
 * newest member activity (its progress detail), so the card reads like the
 * live tool row does for a single call. Once every member settles, it is the
 * batch outcome in web's CTA wording.
 */
export function agentSpawnSummary(
  spawn: NonNullable<WorkLogEntry["agentSpawn"]>,
  batchStatus: WorkLogToolLifecycleStatus | undefined,
): AgentSpawnSummary {
  const members = agentSpawnMembers(spawn).map((agent) => {
    const tone = agentSpawnTone(agent.status);
    // While working, the newest signal wins: a tool call the agent made
    // after its last progress report is what it is doing now.
    const tool = agent.lastTool;
    const toolIsNewer =
      tone === "working" && tool !== undefined && tool.updatedAt > agent.updatedAt;
    return {
      title: agent.title,
      status: tone === "working" ? "working" : (agent.status ?? tone),
      tone,
      detail: toolIsNewer ? tool.label : agent.detail,
      updatedAt: toolIsNewer ? tool.updatedAt : agent.updatedAt,
      ...(agent.prompt ? { prompt: agent.prompt } : {}),
    };
  });
  const tone = agentSpawnTone(batchStatus);
  // A workflow's coordinator is not a member; before any member reports the
  // batch has none.
=======
function itemWorkLogTone(item: OrchestrationV2TurnItem): WorkLogPresentationEntry["tone"] {
  if (item.type === "error") return "info";
  if (item.type === "reasoning") return "thinking";
  switch (item.type) {
    case "command_execution":
    case "file_change":
    case "file_search":
    case "web_search":
    case "dynamic_tool":
    case "subagent":
      return "tool";
    default:
      return "info";
  }
}

function itemIcon(item: OrchestrationV2TurnItem): ThreadFeedActivity["icon"] {
  if (item.type === "notification") {
    const source = item.source;
    switch (source.kind) {
      case "subagent":
      case "delegated_task":
        return "hammer";
      case "command":
        return "command";
      case "monitor":
        return "eye";
      case "background_task":
        return "zap";
      default:
        source satisfies never;
        return "zap";
    }
  }
  if (item.type === "dynamic_tool") {
    const classified = classifyToolActivity({
      itemType: "dynamic_tool_call",
      data: { toolName: item.toolName ?? undefined, input: item.input },
    });
    if (classified === "read") {
      return "eye";
    }
    if (classified === "search") return "search";
  }
  switch (item.type) {
    case "reasoning":
      return "agent";
    case "command_execution":
      return "command";
    case "file_change":
      return "edit";
    case "file_search":
      return "search";
    case "web_search":
      return "globe";
    case "approval_request":
      return item.requestKind === "permission" ? "lock" : "message";
    case "user_input_request":
    case "user_message":
    case "assistant_message":
      return "message";
    case "dynamic_tool":
      return "wrench";
    case "subagent":
      return "hammer";
    case "run_interrupt_request":
    case "run_interrupt_result":
    case "system_notice":
      return "warning";
    case "error":
      return item.failure.class === "usage_limit"
        ? item.status === "completed"
          ? "check"
          : "warning"
        : "alert";
    case "checkpoint":
    case "proposed_plan":
    case "todo_list":
      return "check";
    case "compaction":
    case "handoff":
    case "fork":
    case "thread_created":
      return "zap";
    case "secret_request":
      return "lock";
  }
}

function itemToolPresentation(item: OrchestrationV2TurnItem): T3McpToolPresentation | null {
  if (item.type !== "dynamic_tool") {
    return null;
  }
  return resolveT3McpToolPresentation(item.toolName) ?? resolveT3McpToolPresentation(item.title);
}

function itemSummary(
  item: OrchestrationV2TurnItem,
  toolPresentation: T3McpToolPresentation | null = null,
): string {
  if (item.type === "notification") return item.summary;
  if (item.type === "system_notice") return item.message;
  if (item.type === "compaction") return contextCompactionLabel(item);
>>>>>>> upstream-sync-079e4bccd-upstream-renamed
  const title =
    (item.type === "dynamic_tool" ? dynamicToolTitle(item.toolName, item.input) : undefined) ??
    item.title?.trim();
  if (item.type === "subagent") return formatSubagentDisplayTitle(title || "Subagent");
  if (title) return toolPresentation?.displayName ?? capitalizePhrase(title);
  switch (item.type) {
    case "reasoning":
      return "Thinking";
    case "command_execution":
      return "Command";
    case "file_change":
      return item.changes !== undefined && item.changes.length > 1
        ? `Changed ${item.changes.length} files`
        : `Changed ${item.fileName}`;
    case "file_search":
      return item.title?.trim() || formatSearchToolLabel(item) || "Searched files";
    case "web_search":
      return "Searched the web";
    case "approval_request":
      return "Approval requested";
    case "user_input_request":
      return "Input requested";
    case "checkpoint":
      return "Checkpoint captured";
    case "run_interrupt_request":
      return "Interrupt requested";
    case "run_interrupt_result":
      return "Run interrupted";
    case "error":
      return item.failure.class === "usage_limit" ? "Usage limit reached" : "Provider error";
    case "handoff":
      return "Context handed off";
    case "fork":
      return "Thread forked";
    case "thread_created":
      return "Thread created";
    case "secret_request":
      return item.label;
    case "dynamic_tool": {
      const classified = classifyToolActivity({
        itemType: "dynamic_tool_call",
        data: { toolName: item.toolName ?? undefined, input: item.input },
      });
      if (classified === "read") {
        const [path] = collectToolFilePaths({ input: item.input });
        return formatReadToolLabel(path ?? "");
      }
      if (classified === "search") {
        return formatSearchToolLabel({ input: item.input }) ?? item.toolName ?? "Tool call";
      }
      return toolPresentation?.displayName ?? item.toolName ?? "Tool call";
    }
    case "proposed_plan":
      return "Proposed plan";
    case "todo_list":
      return "Plan updated";
    case "user_message":
      return "User message";
    case "assistant_message":
      return "Assistant message";
  }
}

function itemPreview(item: OrchestrationV2TurnItem): string | null {
  switch (item.type) {
    case "reasoning":
      return item.text || null;
    case "command_execution":
      return item.input || null;
    case "file_change":
      return item.fileName;
    case "file_search":
      return item.pattern ?? null;
    case "web_search":
      return item.patterns?.join(", ") ?? null;
    case "approval_request":
      return item.prompt ?? null;
    case "user_input_request":
      return item.questions.map((question) => question.question).join(" · ") || null;
    case "checkpoint":
      return item.files.length === 1
        ? (item.files[0]?.path ?? null)
        : `${item.files.length} changed files`;
    case "run_interrupt_request":
    case "run_interrupt_result":
    case "system_notice":
      return item.message || null;
    case "error":
      return item.failure.message;
    case "compaction":
    case "handoff":
      return item.summary ?? null;
    case "fork":
    case "thread_created":
      return item.targetThreadId;
    case "secret_request":
      return item.reason || null;
    case "subagent":
      return item.result ?? item.progress ?? item.prompt;
    case "dynamic_tool":
      return null;
    case "notification":
      return item.detail ?? null;
    case "proposed_plan":
      return item.markdown || null;
    case "todo_list":
      return `${item.steps.filter((step) => step.status === "completed").length}/${item.steps.length} completed`;
    case "user_message":
    case "assistant_message":
      return item.text || null;
  }
}

function toWorkLogEntry(
  item: OrchestrationV2TurnItem,
  createdAt: string,
  summary: string,
  detail: string | null,
): WorkLogPresentationEntry {
  const title = item.title?.trim() || null;
  const common = {
    ...extractToolActivityPresentation(item),
    id: item.id,
    createdAt,
    label: summary,
    tone: itemWorkLogTone(item),
    itemType: item.type,
    toolLifecycleStatus: itemLifecycleStatus(item),
    structuredPayload: item,
    ...(item.type === "user_input_request" && item.questionAnswer
      ? { questionAnswer: item.questionAnswer }
      : {}),
  } as const;

  switch (item.type) {
    case "reasoning":
      return { ...common, ...(item.text ? { detail: item.text } : {}) };
    case "command_execution":
      return {
        ...common,
        command: item.input,
        rawCommand: item.input,
        toolTitle: title ?? "Command",
        toolData: item,
      };
    case "file_change":
      return {
        ...common,
        changedFiles: [item.fileName],
        toolTitle: title ?? "File change",
        toolData: item,
      };
    case "file_search":
      return {
        ...common,
        ...(item.pattern ? { detail: item.pattern } : {}),
        toolTitle: title ?? "File search",
        toolData: item,
      };
    case "web_search":
      return {
        ...common,
        ...(item.patterns?.length ? { detail: item.patterns.join(", ") } : {}),
        toolTitle: title ?? "Web search",
        toolData: item,
      };
    case "checkpoint":
      return { ...common, changedFiles: item.files.map((file) => file.path), toolData: item };
    case "approval_request":
      return {
        ...common,
        ...(item.prompt ? { detail: item.prompt } : {}),
        requestKind: item.requestKind,
        toolData: item,
      };
    case "dynamic_tool":
      return {
        ...common,
        toolTitle: title ?? item.toolName ?? "Tool",
        toolData: { input: item.input, output: item.output },
      };
    default:
      return { ...common, ...(detail ? { detail } : {}), toolData: item };
  }
}

/** Expanded detail for a row, from its wire item or the full item from getTurnItem. */
export function formatItemFullDetail(
  row: OrchestrationV2ProjectedTurnItem,
  item: OrchestrationV2TurnItem,
): string {
  return JSON.stringify(
    {
      visibility: row.visibility,
      sourceThreadId: row.sourceThreadId,
      sourceItemId: row.sourceItemId,
      item: toolItemForDisplay(item),
    },
    null,
    2,
  );
}

function toFeedActivity(
  row: OrchestrationV2ProjectedTurnItem,
  attemptId: RunAttemptId | null,
): ThreadFeedActivity {
  const item = row.item;
  const toolPresentation = itemToolPresentation(item);
  const summary = itemSummary(item, toolPresentation);
  const detail = item.type === "notification" ? null : itemPreview(item);
  const createdAt = DateTime.formatIso(item.startedAt ?? item.updatedAt);
  const workEntry = toWorkLogEntry(item, createdAt, summary, detail);
  const readPaths =
    item.type === "dynamic_tool" && toolGroupAction(workEntry) === "read"
      ? collectToolFilePaths(item)
      : null;
  const getFullDetail = memoizeValue(() =>
    readPaths ? readPaths.join("\n") || null : formatItemFullDetail(row, item),
  );
  const getCopyText = memoizeValue(() =>
    [summary, detail, getFullDetail()]
      .filter(
        (value, index, values): value is string =>
          Boolean(value) && values.indexOf(value) === index,
      )
      .join("\n"),
  );
  return {
    id: `${row.visibility}:${row.sourceThreadId}:${row.sourceItemId}`,
    createdAt,
    runId: item.runId,
    attemptId,
    summary,
    detail,
    canExpand:
      !(item.type === "error" && item.status === "failed") &&
      (readPaths
        ? readPaths.length > 0 || turnItemNeedsDetailFetch(item)
        : turnItemHasDetail(item) || workEntry.questionAnswer !== undefined),
    // Read rows show their paths, then the fetched file contents.
    fetchesDetail: turnItemNeedsDetailFetch(item),
    getFullDetail,
    getCopyText,
    icon: workEntry.toolSurface ?? itemIcon(item),
    logo: toolPresentation?.logo ?? null,
    toolLike: itemIsToolLike(item),
    prominent: itemIsProminent(item) || (item.type === "error" && item.status === "failed"),
    status:
      item.type === "error" && item.failure.class === "usage_limit"
        ? itemStatus(item)
        : workEntryDisplayIndicatesToolFailure(workEntry)
          ? "failure"
          : itemStatus(item),
    lifecycleStatus: itemLifecycleStatus(item),
    workEntry,
    projectedItem: row,
  };
}

function singleToolCallLabel(activity: ThreadFeedActivity, expanded: boolean): string {
  if (activity.workEntry.itemType === "reasoning")
    return expanded
      ? "Thought"
      : compactWorkEntryText(activity.workEntry.detail ?? "") || "Thought";
  const presentation = resolveWorkEntryToolPresentation(activity.workEntry, "completed");
  if (presentation) return presentation.displayName;
  if (activity.workEntry.commandDescription) return activity.workEntry.commandDescription;
  const command = activity.workEntry.command?.trim();
  return command || activity.summary;
}

function isEmptyMessage(entry: RawThreadFeedEntry): boolean {
  return (
    entry.type === "message" &&
    entry.message.text.trim().length === 0 &&
    entry.message.attachments.length === 0
  );
}

function groupAdjacentActivities(entries: ReadonlyArray<RawThreadFeedEntry>): ThreadFeedEntry[] {
  const childrenByRun = new Map<RunId, Set<string>>();
  for (const entry of entries) {
    if (entry.type !== "activity") continue;
    const item = entry.activity.projectedItem.item;
    if (item.type !== "subagent" || item.origin !== "app_owned" || item.runId === null) continue;
    const children = childrenByRun.get(item.runId) ?? new Set<string>();
    children.add(item.subagentId);
    childrenByRun.set(item.runId, children);
  }
  const grouped: ThreadFeedEntry[] = [];
  let firstActivityEntry: Extract<RawThreadFeedEntry, { readonly type: "activity" }> | null = null;
  let openGroupActivities: ThreadFeedActivity[] = [];
  const flushGroup = () => {
    if (firstActivityEntry === null) return;
    const cached = activityGroupsCache.get(firstActivityEntry.activity);
    if (
      cached &&
      cached.activities.length === openGroupActivities.length &&
      cached.activities.every((activity, index) => activity === openGroupActivities[index])
    ) {
      grouped.push(cached);
    } else {
      const group: ThreadFeedActivityGroup = {
        type: "activity-group",
        id: firstActivityEntry.id,
        createdAt: firstActivityEntry.createdAt,
        runId: firstActivityEntry.runId,
        activities: openGroupActivities,
      };
      activityGroupsCache.set(firstActivityEntry.activity, group);
      grouped.push(group);
    }
    firstActivityEntry = null;
    openGroupActivities = [];
  };

  for (const entry of entries) {
    // A successful delegation is already represented by its durable child card.
    // Pending, failed and unmatched calls remain visible, even with identical prompts.
    if (entry.type === "activity") {
      const item = entry.activity.projectedItem.item;
      if (
        item.type === "dynamic_tool" &&
        item.runId !== null &&
        (item.status === "running" || item.status === "completed") &&
        resolveT3McpToolDefinition(item.toolName)?.summaryAction === "delegate" &&
        !workEntryDisplayIndicatesToolFailure(entry.activity.workEntry)
      ) {
        const output = compactDynamicToolOutput(item.output);
        if (
          !output?.isError &&
          output?.taskId !== undefined &&
          childrenByRun.get(item.runId)?.has(output.taskId)
        )
          continue;
      }
    }
    // Skip empty messages so they don't break activity grouping.
    if (isEmptyMessage(entry)) {
      continue;
    }

    if (entry.type !== "activity") {
      flushGroup();
      grouped.push(entry);
      continue;
    }

    const isStandaloneActivity =
      entry.activity.projectedItem.item.type === "compaction" ||
      entry.activity.projectedItem.item.type === "handoff" ||
      entry.activity.projectedItem.item.type === "notification";
    if (
      isStandaloneActivity ||
      entry.activity.prominent ||
      (entry.activity.projectedItem.item.type === "subagent") !==
        (firstActivityEntry?.activity.projectedItem.item.type === "subagent") ||
      firstActivityEntry?.runId !== entry.runId ||
      (entry.activity.projectedItem.item.type === "subagent" &&
        firstActivityEntry?.activity.projectedItem.item.providerTurnId !==
          entry.activity.projectedItem.item.providerTurnId) ||
      (entry.activity.projectedItem.item.type !== "subagent" &&
        firstActivityEntry?.activity.attemptId !== entry.activity.attemptId)
    ) {
      flushGroup();
    }
    firstActivityEntry ??= entry;
    openGroupActivities.push(entry.activity);
    if (isStandaloneActivity || entry.activity.prominent) {
      flushGroup();
    }
  }
  flushGroup();
  return grouped;
}

function computeElapsedMs(startIso: string, endIso: string): number | null {
  const start = Date.parse(startIso);
  const end = Date.parse(endIso);
  return Number.isFinite(start) && Number.isFinite(end) ? Math.max(0, end - start) : null;
}

function maxIsoTimestamp(left: string | null, right: string | null): string | null {
  if (left === null) return right;
  if (right === null) return left;
  return Date.parse(right) > Date.parse(left) ? right : left;
}

function unsettledRunId(latestRun: ThreadFeedLatestRun | null): RunId | null {
  return threadFeedRunIsUnsettled(latestRun) ? latestRun.runId : null;
}

export function threadFeedRunIsUnsettled(
  run: ThreadFeedLatestRun | null,
): run is ThreadFeedLatestRun {
  if (run === null || run.status === "queued") return false;
  return (
    run.completedAt === null ||
    run.status === "preparing" ||
    run.status === "starting" ||
    run.status === "running" ||
    run.status === "waiting"
  );
}

export function threadFeedActivityIsVisible(
  activity: Pick<ThreadFeedActivity, "prominent" | "status" | "toolLike"> &
    Partial<Pick<ThreadFeedActivity, "lifecycleStatus">>,
): boolean {
  return (
    activity.prominent ||
    activity.lifecycleStatus === "stopped" ||
    activity.lifecycleStatus === "declined" ||
    activity.lifecycleStatus === "idle" ||
    !(activity.toolLike && activity.status === "neutral")
  );
}

interface ThreadFeedRunFold {
  readonly runId: RunId;
  readonly createdAt: string;
  readonly hiddenEntryIds: ReadonlySet<string>;
  readonly label: string;
}

export function failedFeedRunIds(
  feed: ReadonlyArray<ThreadFeedEntry>,
  latestRun: ThreadFeedLatestRun | null,
) {
  const failed = new Set<RunId>();
  if (latestRun?.status === "failed") failed.add(latestRun.runId);
  for (const entry of feed) {
    if (entry.type !== "activity-group") continue;
    for (const activity of entry.activities) {
      const item = activity.projectedItem.item;
      if (
        item.type === "error" &&
        item.status === "failed" &&
        item.parentItemId === null &&
        item.runId !== null
      )
        failed.add(item.runId);
    }
  }
  return failed;
}

/**
 * A prompt without a run (a provider-native subagent, or a turn imported from
 * V1) folds its response like a run. `runlessWorkActive` keeps the latest
 * runless response open; V2 work must not reopen imported turns.
 */
function deriveThreadFeedRunFolds(
  feed: ReadonlyArray<ThreadFeedEntry>,
  latestRun: ThreadFeedLatestRun | null,
  runlessWorkActive: boolean,
): ReadonlyMap<string, ThreadFeedRunFold> {
  const firstAssistantMessageIdByRun = new Map<RunId, string>();
  const terminalAssistantMessageIdByRun = new Map<RunId, string>();
  const interruptedRunIds = new Set<RunId>();
  const failedRunIds = failedFeedRunIds(feed, latestRun);
  const groupsByRunId = new Map<
    RunId,
    { entries: ThreadFeedEntry[]; startBoundary: string | null }
  >();
  // Fold state is keyed by run, so each runless prompt lends its response a
  // stable key of its own. Decide per prompt, not per thread: a V1 thread's
  // first V2 run must not unfold every imported turn above it.
  let runlessKey: RunId | null = null;
  let pendingUserBoundary: string | null = null;
  for (const entry of feed) {
    if (entry.type === "message" && entry.message.role === "user") {
      pendingUserBoundary = entry.message.createdAt;
      runlessKey = entry.message.runId == null ? RunId.make(`runless:${entry.id}`) : null;
      continue;
    }
    const runId =
      entry.type === "message" && entry.message.role === "assistant"
        ? (entry.message.runId ?? runlessKey)
        : entry.type === "activity-group" || entry.type === "html-render"
          ? (entry.runId ?? runlessKey)
          : null;
    if (!runId) continue;
    let group = groupsByRunId.get(runId);
    if (!group) {
      group = { entries: [], startBoundary: pendingUserBoundary };
      pendingUserBoundary = null;
      groupsByRunId.set(runId, group);
    }
    group.entries.push(entry);
    if (entry.type === "message") {
      if (!firstAssistantMessageIdByRun.has(runId)) {
        firstAssistantMessageIdByRun.set(runId, entry.id);
      }
      terminalAssistantMessageIdByRun.set(runId, entry.id);
    }
    if (entry.type !== "activity-group") continue;
    for (const activity of entry.activities) {
      const item = activity.projectedItem.item;
      if (item.type === "run_interrupt_result") interruptedRunIds.add(runId);
      if (
        runId === runlessKey &&
        item.type === "error" &&
        item.status === "failed" &&
        item.parentItemId === null
      ) {
        failedRunIds.add(runId);
      }
    }
  }

  const activeRunId = unsettledRunId(latestRun);
  const foldsByAnchorId = new Map<string, ThreadFeedRunFold>();
  for (const [runId, group] of groupsByRunId) {
    if (
      runId === activeRunId ||
      (runlessWorkActive && runId === runlessKey) ||
      interruptedRunIds.has(runId) ||
      failedRunIds.has(runId) ||
      group.entries.some((entry) => entry.type === "message" && entry.message.streaming)
    ) {
      continue;
    }
    const firstAssistantId = firstAssistantMessageIdByRun.get(runId);
    const terminalAssistantId = terminalAssistantMessageIdByRun.get(runId);
    const hiddenEntryIds = new Set(
      group.entries
        .filter(
          (entry) =>
            entry.id !== firstAssistantId &&
            entry.id !== terminalAssistantId &&
            entry.type !== "html-render" &&
            !(
              entry.type === "activity-group" &&
              entry.activities.some(
                (activity) =>
                  activity.prominent ||
                  activity.projectedItem.item.type === "notification" ||
                  activity.projectedItem.item.type === "handoff",
              )
            ),
        )
        .map((entry) => entry.id),
    );
    const firstEntry = group.entries[0];
    const firstHiddenEntry = group.entries.find((entry) => hiddenEntryIds.has(entry.id));
    const lastEntry = group.entries.at(-1);
    if (!firstHiddenEntry || !firstEntry || !lastEntry) continue;
    const hidesNonCompactionWork = group.entries.some(
      (entry) =>
        hiddenEntryIds.has(entry.id) &&
        !(entry.type === "activity-group" && isContextCompactionActivityGroup(entry)),
    );
    if (!hidesNonCompactionWork) continue;
    const terminalEntry = terminalAssistantId
      ? group.entries.find((entry) => entry.id === terminalAssistantId)
      : null;
    const latestRunMatches = latestRun?.runId === runId;
    const lastEntryEnd =
      lastEntry.type === "message" ? lastEntry.message.updatedAt : lastEntry.createdAt;
    const elapsedMs =
      latestRunMatches && latestRun.startedAt && latestRun.completedAt
        ? computeElapsedMs(latestRun.startedAt, latestRun.completedAt)
        : computeElapsedMs(
            group.startBoundary ?? firstEntry.createdAt,
            maxIsoTimestamp(
              terminalEntry?.type === "message" ? terminalEntry.message.updatedAt : null,
              lastEntryEnd,
            ) ?? lastEntryEnd,
          );
    const duration = elapsedMs === null ? null : formatDuration(elapsedMs);
    const interrupted =
      latestRunMatches && (latestRun.status === "interrupted" || latestRun.status === "cancelled");
    foldsByAnchorId.set(firstHiddenEntry.id, {
      runId,
      createdAt: firstHiddenEntry.createdAt,
      hiddenEntryIds,
      label: interrupted
        ? duration
          ? `You stopped after ${duration}`
          : "You stopped this response"
        : duration
          ? `Worked for ${duration}`
          : "Worked",
    });
  }
  return foldsByAnchorId;
}

const supersededReasoningGroups = new WeakMap<ThreadFeedActivityGroup, ThreadFeedActivityGroup>();
const trailingReasoningGroups = new WeakMap<ThreadFeedActivityGroup, ThreadFeedActivityGroup>();

/** A steer or subsequent activity ends thinking even if the provider omits its completion. */
function settleSupersededReasoning(
  entry: Exclude<ThreadFeedEntry, { readonly type: "run-fold" | "work-toggle" | "thinking" }>,
  tail: boolean,
) {
  if (entry.type !== "activity-group") return entry;
  const cache = tail ? trailingReasoningGroups : supersededReasoningGroups;
  const cached = cache.get(entry);
  if (cached) return cached;
  const activities = entry.activities.map((activity, index) =>
    activity.workEntry.itemType === "reasoning" &&
    activity.lifecycleStatus === "inProgress" &&
    (!tail || index < entry.activities.length - 1)
      ? {
          ...activity,
          lifecycleStatus: "completed" as const,
          status: "success" as const,
          workEntry: { ...activity.workEntry, toolLifecycleStatus: "completed" as const },
        }
      : activity,
  );
  const settled = activities.some((activity, index) => activity !== entry.activities[index])
    ? { ...entry, activities }
    : entry;
  cache.set(entry, settled);
  return settled;
}

export function deriveThreadFeedPresentation(
  feed: ReadonlyArray<ThreadFeedEntry>,
  latestRun: ThreadFeedLatestRun | null,
  expandedRunIds: ReadonlySet<RunId>,
  expandedWorkGroupIds: ReadonlySet<string> = new Set(),
  activeWorkStartedAt: string | null = null,
  /** The live work is a provider-native subagent's runless root turn. */
  runlessWorkActive = false,
): ThreadFeedEntry[] {
  const retainedFeed = feed.filter(
    (entry) =>
      entry.type !== "run-fold" && entry.type !== "work-toggle" && entry.type !== "thinking",
  );
  const sourceFeed = retainedFeed.map((entry, index) =>
    settleSupersededReasoning(entry, index === retainedFeed.length - 1),
  );
  const failedRunIds = failedFeedRunIds(sourceFeed, latestRun);
  const activeTailGroup = sourceFeed.at(-1);
  const activeRunId = unsettledRunId(latestRun);
  const isWorking = activeWorkStartedAt !== null && latestRun?.status !== "preparing";
  const foldsByAnchorId = deriveThreadFeedRunFolds(
    sourceFeed,
    latestRun,
    isWorking && runlessWorkActive,
  );
  const collapsedEntryIds = new Set<string>();
  for (const fold of foldsByAnchorId.values()) {
    if (!expandedRunIds.has(fold.runId)) {
      for (const entryId of fold.hiddenEntryIds) collapsedEntryIds.add(entryId);
    }
  }
  const result: ThreadFeedEntry[] = [];
  for (const entry of sourceFeed) {
    // A provider-native subagent works without a run: its null-run tail is
    // live only while that runless work is active.
    const isActiveTailGroup =
      isWorking &&
      (activeRunId !== null || runlessWorkActive) &&
      entry.type === "activity-group" &&
      activeTailGroup?.type === "activity-group" &&
      activeTailGroup.id === entry.id &&
      entry.runId === activeRunId;
    const fold = foldsByAnchorId.get(entry.id);
    if (fold) {
      const expanded = expandedRunIds.has(fold.runId);
      let row = runFoldRowsCache.get(entry);
      if (
        !row ||
        row.runId !== fold.runId ||
        row.createdAt !== fold.createdAt ||
        row.label !== fold.label ||
        row.expanded !== expanded
      ) {
        row = {
          type: "run-fold",
          id: `run-fold:${fold.runId}`,
          createdAt: fold.createdAt,
          runId: fold.runId,
          label: fold.label,
          expanded,
        };
        runFoldRowsCache.set(entry, row);
      }
      result.push(row);
    }
    if (!collapsedEntryIds.has(entry.id)) {
      if (
        entry.type === "activity-group" &&
        entry.runId !== null &&
        failedRunIds.has(entry.runId)
      ) {
        let rows = failedActivityGroupsCache.get(entry);
        if (!rows) {
          rows =
            entry.activities.length === 1
              ? [entry]
              : entry.activities.map((activity) => ({
                  type: "activity-group" as const,
                  id: activity.id,
                  createdAt: activity.createdAt,
                  runId: activity.runId,
                  activities: [activity],
                }));
          failedActivityGroupsCache.set(entry, rows);
        }
        result.push(...rows);
        continue;
      }
      appendPresentedFeedEntry(
        result,
        entry,
        expandedWorkGroupIds,
        activeRunId,
        isWorking,
        isActiveTailGroup,
      );
    }
  }
  // Keep exactly one live slot while a run is working. When no tool row can
  // carry it yet (or the latest call failed), the slot reads "Thinking".
  if (
    isWorking &&
    activeWorkStartedAt !== null &&
    !result.some(
      (row) =>
        (row.type === "work-toggle" && row.shimmer) ||
        (row.type === "activity-group" &&
          isContextCompactionActivityGroup(row) &&
          row.runId === activeRunId &&
          row.activities[0]?.projectedItem.item.status === "running"),
    )
  ) {
    result.push(thinkingRow(activeWorkStartedAt, activeRunId));
  }
  return result.map((row, index) => {
    if (!isWorkLogFeedRow(row) || !isWorkLogFeedRow(result[index + 1])) return row;
    let continued = continuedWorkLogRows.get(row);
    if (!continued) {
      continued = { ...row, continuesWorkLog: true };
      continuedWorkLogRows.set(row, continued);
    }
    return continued;
  });
}

const continuedWorkLogRows = new WeakMap<ThreadFeedEntry, ThreadFeedEntry>();

function isWorkLogFeedRow(row: ThreadFeedEntry | undefined): boolean {
  return (
    row !== undefined &&
    (row.type === "work-toggle" ||
      row.type === "thinking" ||
      (row.type === "activity-group" &&
        !isContextCompactionActivityGroup(row) &&
        !isContextHandoffActivityGroup(row) &&
        row.activities.every(
          (activity) =>
            !activity.prominent &&
            activity.projectedItem.item.type !== "notification" &&
            activity.projectedItem.item.type !== "subagent",
        )))
  );
}

/** Shared by the trailing live tool row and its Thinking fallback. */
export const LIVE_ACTIVITY_ROW_ID = "live-activity-row";

function thinkingRow(createdAt: string, runId: RunId | null) {
  if (cachedThinkingRow?.createdAt !== createdAt || cachedThinkingRow.runId !== runId) {
    cachedThinkingRow = { type: "thinking", id: LIVE_ACTIVITY_ROW_ID, createdAt, runId };
  }
  return cachedThinkingRow;
}

function appendPresentedFeedEntry(
  result: ThreadFeedEntry[],
  entry: Exclude<ThreadFeedEntry, { readonly type: "run-fold" | "work-toggle" | "thinking" }>,
  expandedWorkGroupIds: ReadonlySet<string>,
  activeRunId: RunId | null,
  isWorking: boolean,
  activeTail: boolean,
): void {
  if (entry.type !== "activity-group") {
    result.push(entry);
    return;
  }
  if (
    isContextCompactionActivityGroup(entry) ||
    isContextHandoffActivityGroup(entry) ||
    isUserInputActivityGroup(entry) ||
    entry.activities[0]?.projectedItem.item.type === "subagent"
  ) {
    result.push(entry);
    return;
  }

  let cached = presentedActivityGroupsCache.get(entry);
  if (
    !cached ||
    cached.activeRunId !== activeRunId ||
    cached.isWorking !== isWorking ||
    cached.activeTail !== activeTail ||
    cached.rows.some(
      (row) => row.type === "work-toggle" && expandedWorkGroupIds.has(row.groupId) !== row.expanded,
    )
  ) {
    const rows: ThreadFeedEntry[] = [];
    appendActivityGroupRows(rows, entry, expandedWorkGroupIds, activeRunId, isWorking, activeTail);
    cached = { activeRunId, isWorking, activeTail, rows };
    presentedActivityGroupsCache.set(entry, cached);
  }
  for (const row of cached.rows) {
    result.push(row);
  }
}

function appendActivityGroupRows(
  result: ThreadFeedEntry[],
  entry: ThreadFeedActivityGroup,
  expandedWorkGroupIds: ReadonlySet<string>,
  activeRunId: RunId | null,
  isWorking: boolean,
  activeTail: boolean,
): void {
  const groupAnchorIdByActivityId = new Map<string, string>();
  let groupAnchorId: string | null = null;
  for (const activity of entry.activities) {
    const item = activity.projectedItem.item;
    if (activity.prominent || (item.type === "error" && item.status === "failed")) {
      groupAnchorId = null;
      continue;
    }
    groupAnchorId ??= activity.id;
    groupAnchorIdByActivityId.set(activity.id, groupAnchorId);
  }
  const activities = entry.activities.filter(
    (activity) =>
      threadFeedActivityIsVisible(activity) ||
      (isWorking && activity.lifecycleStatus === "inProgress" && activity.runId === activeRunId),
  );
  if (activities.length === 0) {
    return;
  }

  let groupableRun: ThreadFeedActivity[] = [];
  const flushGroupableRun = (isTrailingRun: boolean) => {
    if (groupableRun.length === 0) return;
    appendToolGroupRows(
      result,
      entry,
      groupableRun,
      `work-group:${groupAnchorIdByActivityId.get(groupableRun[0]!.id) ?? groupableRun[0]!.id}`,
      expandedWorkGroupIds,
      activeRunId,
      isWorking,
      activeTail && isTrailingRun,
    );
    groupableRun = [];
  };
  for (const activity of activities) {
    const item = activity.projectedItem.item;
    const severeProviderError = item.type === "error" && item.status === "failed";
    if (!activity.prominent && !severeProviderError && item.type !== "notification") {
      groupableRun.push(activity);
      continue;
    }
    flushGroupableRun(false);
    result.push({
      type: "activity-group",
      id: activity.id,
      createdAt: activity.createdAt,
      runId: activity.runId,
      activities: [activity],
    });
  }
  flushGroupableRun(true);
}

function appendToolGroupRows(
  result: ThreadFeedEntry[],
  sourceGroup: Extract<ThreadFeedEntry, { readonly type: "activity-group" }>,
  activities: ReadonlyArray<ThreadFeedActivity>,
  groupId: string,
  expandedWorkGroupIds: ReadonlySet<string>,
  activeRunId: RunId | null,
  isWorking: boolean,
  activeTail: boolean,
): void {
  const expanded = expandedWorkGroupIds.has(groupId);
  const latestActiveActivity = activities.findLast(
    (activity) =>
      isWorking && activity.lifecycleStatus === "inProgress" && activity.runId === activeRunId,
  );
  const active = latestActiveActivity !== undefined;
  const live = activeTail || active;
  const latestActivity = latestActiveActivity ?? activities.at(-1)!;
  // A successful trailing call remains the live slot until the next activity.
  // Failed/stopped calls hand that slot to the Thinking row.
  const shimmer = activeTail && (active || latestActivity.status === "success");
  const singleActivity = activities.length === 1 ? latestActivity : null;
  const groupSummary = summarizeToolGroup(activities.map((activity) => activity.workEntry));
  const summary = live
    ? expanded && latestActivity.workEntry.itemType === "reasoning"
      ? latestActivity.lifecycleStatus === "inProgress"
        ? "Thinking"
        : "Thought"
      : liveToolActivitySummary(latestActivity, live)
    : singleActivity !== null &&
        singleActivity.toolLike &&
        toolGroupAction(singleActivity.workEntry) !== "edit"
      ? singleToolCallLabel(singleActivity, expanded)
      : singleActivity !== null && !singleActivity.toolLike
        ? singleActivity.workEntry.label
        : groupSummary.summary;
  const primarySourceActivity = activities.find(
    (activity) => activity.workEntry.toolSource !== undefined,
  );
  const primarySourceKey = primarySourceActivity?.workEntry.toolSource?.key;
  const primarySourceIcon = primarySourceKey
    ? (activities.find(
        (activity) =>
          activity.workEntry.toolSource?.key === primarySourceKey &&
          activity.workEntry.toolIcon !== undefined,
      )?.workEntry.toolIcon ?? primarySourceActivity?.workEntry.toolSource?.icon)
    : undefined;
  const groupToolSurface =
    primarySourceActivity?.workEntry.toolSurface ??
    latestActivity.workEntry.toolSurface ??
    activities.findLast((activity) => activity.workEntry.toolSurface !== undefined)?.workEntry
      .toolSurface;
  const groupToolIcon =
    primarySourceIcon ??
    latestActivity.workEntry.toolIcon ??
    activities.findLast((activity) => activity.workEntry.toolIcon !== undefined)?.workEntry
      .toolIcon;
  const summaryToolIcon = live
    ? resolveWorkEntryToolPresentation(latestActivity.workEntry)?.icon
    : singleActivity !== null &&
        singleActivity.toolLike &&
        toolGroupAction(singleActivity.workEntry) !== "edit"
      ? resolveWorkEntryToolPresentation(singleActivity.workEntry, "completed")?.icon
      : undefined;
  result.push({
    type: "work-toggle",
    id: shimmer ? LIVE_ACTIVITY_ROW_ID : `${live ? "work-live" : "work-toggle"}:${groupId}`,
    createdAt: sourceGroup.createdAt,
    runId: sourceGroup.runId,
    groupId,
    hiddenCount: activities.length,
    expanded,
    summary,
    summaryKind: toolGroupSummaryKind(
      (live ? [latestActivity] : activities).map((activity) => activity.workEntry),
    ),
    ...(groupToolSurface ? { toolSurface: groupToolSurface } : {}),
    ...(groupToolIcon ? { toolIcon: groupToolIcon } : {}),
    ...(summaryToolIcon ? { summaryToolIcon } : {}),
    hasFailure: (() => {
      const lastToolLike = activities.findLast((activity) => activity.toolLike);
      return (
        lastToolLike !== undefined && workEntryDisplayIndicatesToolFailure(lastToolLike.workEntry)
      );
    })(),
    live,
    shimmer,
  });
  if (!expanded) return;
  result.push({
    type: "activity-group",
    id: `work-details:${groupId}`,
    createdAt: activities[0]!.createdAt,
    runId: activities[0]!.runId,
    activities: activities.map((activity) => ({
      ...activity,
      groupedToolDetail: true,
      live:
        isWorking &&
        activity.id === latestActivity.id &&
        activity.lifecycleStatus === "inProgress" &&
        activity.runId === activeRunId,
    })),
  });
}

function liveToolActivitySummary(activity: ThreadFeedActivity, presentTense: boolean): string {
  const status = liveActivityToolStatus(activity.lifecycleStatus, presentTense);
  if (activity.workEntry.itemType === "reasoning") {
    return (
      activity.workEntry.detail?.trim().replace(/\s+/g, " ") ||
      (status === "inProgress" ? "Thinking" : "Thought")
    );
  }
  const presentation = resolveWorkEntryToolPresentation({
    ...activity.workEntry,
    toolLifecycleStatus: status,
  });
  if (presentation) return presentation.displayName;
  if (activity.workEntry.commandDescription) return activity.workEntry.commandDescription;
  const command = activity.workEntry.command?.trim();
  if (command) {
    const program = commandProgramName(command);
    const verb =
      status === "inProgress"
        ? "Running"
        : status === "failed"
          ? "Failed"
          : status === "declined"
            ? "Declined"
            : status === "stopped"
              ? "Stopped"
              : "Ran";
    return `${verb} ${program ?? "command"}`;
  }
  return activity.detail ?? activity.summary;
}

export function setPendingUserInputCustomAnswer(
  question: ThreadUserInputQuestion,
  draft: PendingUserInputDraftAnswer | undefined,
  customAnswer: string,
): PendingUserInputDraftAnswer {
  if (question.allowCustomAnswer === false) {
    return draft ?? {};
  }

  const selectedOptionValues =
    customAnswer.trim().length > 0
      ? undefined
      : normalizeSelectedOptionValues(question, draft?.selectedOptionValues);
  return {
    customAnswer,
    ...(selectedOptionValues && selectedOptionValues.length > 0 ? { selectedOptionValues } : {}),
  };
}

export function isPendingUserInputOptionSelected(
  question: ThreadUserInputQuestion,
  draft: PendingUserInputDraftAnswer | undefined,
  optionValue: string,
): boolean {
  if (question.allowCustomAnswer !== false && normalizeDraftAnswer(draft?.customAnswer)) {
    return false;
  }

  const resolvedOptionValue = resolvePendingUserInputOptionValue(question, optionValue);
  return (
    resolvedOptionValue !== null &&
    normalizeSelectedOptionValues(question, draft?.selectedOptionValues).includes(
      resolvedOptionValue,
    )
  );
}

export function togglePendingUserInputOptionSelection(
  question: ThreadUserInputQuestion,
  draft: PendingUserInputDraftAnswer | undefined,
  optionValue: string,
): PendingUserInputDraftAnswer {
  const resolvedOptionValue = resolvePendingUserInputOptionValue(question, optionValue);
  if (resolvedOptionValue === null) {
    return draft ?? {};
  }

  if (question.multiSelect) {
    const selectedOptionValues = normalizeSelectedOptionValues(
      question,
      draft?.selectedOptionValues,
    );
    const nextSelectedOptionValues = selectedOptionValues.includes(resolvedOptionValue)
      ? selectedOptionValues.filter((value) => value !== resolvedOptionValue)
      : [...selectedOptionValues, resolvedOptionValue];

    return {
      customAnswer: "",
      ...(nextSelectedOptionValues.length > 0
        ? { selectedOptionValues: nextSelectedOptionValues }
        : {}),
    };
  }

  return {
    customAnswer: "",
    selectedOptionValues: [resolvedOptionValue],
  };
}

export function buildPendingUserInputAnswers(
  questions: ReadonlyArray<ThreadUserInputQuestion>,
  draftAnswers: Record<string, PendingUserInputDraftAnswer>,
): Record<string, string | ReadonlyArray<string>> | null {
  const answers: Record<string, string | ReadonlyArray<string>> = {};

  for (const question of questions) {
    const answer = resolvePendingUserInputAnswer(question, draftAnswers[question.id]);
    if (answer === null) {
      return null;
    }
    answers[question.id] = answer;
  }

  return answers;
}

/**
 * Projects the server-authored visible sequence into mobile row presentation.
 * It deliberately preserves the incoming order and never rebuilds chat from
 * separate message, plan, or work-entry collections.
 */
export function buildThreadFeed(
  visibleTurnItems: ReadonlyArray<OrchestrationV2ProjectedTurnItem>,
  options?: {
    readonly anchoredMessages?: ReadonlyArray<LocalThreadMessage>;
    readonly attempts?: ReadonlyArray<OrchestrationV2RunAttempt>;
    readonly nodes?: ReadonlyArray<OrchestrationV2ExecutionNode>;
  },
): ThreadFeedEntry[] {
  const entries: RawThreadFeedEntry[] = [];
  const attemptByRootNodeId = new Map(
    (options?.attempts ?? []).map((attempt) => [attempt.rootNodeId, attempt] as const),
  );
  const nodeById = new Map((options?.nodes ?? []).map((node) => [node.id, node] as const));
  const resolveAttemptId = (item: OrchestrationV2TurnItem): RunAttemptId | null => {
    if (item.nodeId === null || item.runId === null) return null;
    let nodeId: OrchestrationV2ExecutionNode["id"] | null = item.nodeId;
    const visited = new Set<OrchestrationV2ExecutionNode["id"]>();
    while (nodeId !== null && !visited.has(nodeId)) {
      visited.add(nodeId);
      const directAttempt = attemptByRootNodeId.get(nodeId);
      if (directAttempt?.runId === item.runId) return directAttempt.id;
      const node = nodeById.get(nodeId);
      if (node === undefined) return null;
      const rootAttempt = attemptByRootNodeId.get(node.rootNodeId);
      if (rootAttempt?.runId === item.runId) return rootAttempt.id;
      nodeId = node.parentNodeId;
    }
    return null;
  };
  const foldedAnswerMessageIds = new Set(
    visibleTurnItems.flatMap(({ item }) =>
      item.type === "user_input_request" && item.questionAnswer
        ? [`async-answer:${item.questionAnswer.requestId}`]
        : [],
    ),
  );
  for (const row of visibleTurnItems) {
    const item = row.item;
    if (turnItemIsWorkspacePreparation(item)) continue;
    if (item.type === "todo_list" || item.type === "checkpoint") continue;
    if (item.type === "user_message" && foldedAnswerMessageIds.has(item.messageId)) continue;
    // Match the web timeline: only the terminal interrupt result is useful to
    // users; the preceding request is transient bookkeeping.
    if (item.type === "run_interrupt_request") {
      continue;
    }
    const attemptId = resolveAttemptId(item);
    const cached = projectedEntriesCache.get(row);
    if (cached?.attemptId === attemptId) {
      entries.push(cached.entry);
      continue;
    }
    const createdAt = DateTime.formatIso(item.startedAt ?? item.updatedAt);
    // A running or failed render stays an ordinary work row.
    const render =
      item.type === "dynamic_tool" && item.status === "completed"
        ? htmlRenderFromToolItem(item)
        : undefined;
    if (render) {
      const entry: RawThreadFeedEntry = {
        type: "html-render",
        id: `html-render:${row.visibility}:${row.sourceThreadId}:${row.sourceItemId}`,
        createdAt,
        runId: item.runId,
        render,
      };
      projectedEntriesCache.set(row, { attemptId, entry });
      entries.push(entry);
      continue;
    }
    if (item.type === "user_message" || item.type === "assistant_message") {
      const updatedAt = DateTime.formatIso(item.updatedAt);
      const entry: RawThreadFeedEntry = {
        type: "message",
        id: item.messageId,
        createdAt,
        message: {
          id: item.messageId,
          role: item.type === "user_message" ? "user" : "assistant",
          text: item.text,
          ...(item.type === "user_message" && item.context ? { context: item.context } : {}),
          attachments: item.attachments ?? [],
          runId: item.runId,
          streaming: item.type === "assistant_message" && item.streaming,
          ...(item.type === "user_message"
            ? {
                inputIntent: item.inputIntent,
                createdBy: item.createdBy,
                creationSource: item.creationSource,
                ...(item.scheduledTaskId ? { scheduledTaskId: item.scheduledTaskId } : {}),
                ...(item.senderThreadId ? { senderThreadId: item.senderThreadId } : {}),
              }
            : {}),
          visibility: row.visibility,
          sourceThreadId: row.sourceThreadId,
          createdAt,
          updatedAt,
          projectedItem: row,
        },
      };
      projectedEntriesCache.set(row, { attemptId, entry });
      entries.push(entry);
      continue;
    }
    const activity = toFeedActivity(row, attemptId);
    const entry: RawThreadFeedEntry = {
      type: "activity",
      id: activity.id,
      createdAt,
      runId: item.runId,
      activity,
    };
    projectedEntriesCache.set(row, { attemptId, entry });
    entries.push(entry);
  }
  const retainedMessageIds = new Set([
    ...foldedAnswerMessageIds,
    ...entries.flatMap((entry) => (entry.type === "message" ? [entry.id] : [])),
  ]);
  const appendLocalMessage = (message: LocalThreadMessage): RawThreadFeedEntry => {
    const cached = localMessageEntriesCache.get(message);
    if (cached) return cached;
    const entry: Extract<RawThreadFeedEntry, { readonly type: "message" }> = {
      type: "message",
      id: message.id,
      createdAt: message.createdAt,
      message: {
        id: message.id,
        role: message.role === "assistant" ? "assistant" : "user",
        text: message.text,
        ...(message.context ? { context: message.context } : {}),
        attachments: message.attachments ?? [],
        runId: null,
        streaming: message.streaming,
        visibility: "local",
        sourceThreadId: ThreadId.make("local-feedback"),
        createdAt: message.createdAt,
        updatedAt: message.updatedAt,
      },
    };
    localMessageEntriesCache.set(message, entry);
    return entry;
  };
  for (const message of options?.anchoredMessages ?? []) {
    if (retainedMessageIds.has(message.id)) continue;
    retainedMessageIds.add(message.id);
    const entry = appendLocalMessage(message);
    const insertionIndex = entries.findIndex(
      (candidate) => candidate.createdAt > message.createdAt,
    );
    if (insertionIndex === -1) entries.push(entry);
    else entries.splice(insertionIndex, 0, entry);
  }
  return groupAdjacentActivities(entries);
}
