import { EnvironmentId, ThreadId, type OrchestrationShellSnapshot } from "@t3tools/contracts";
import type { InfinitusManifestCommand } from "@t3tools/contracts/infinitus";
import { PRODUCT_NAME } from "@t3tools/contracts/productName";
import { RelayAgentAwarenessPhase } from "@t3tools/contracts/relay";
import { projectThreadAwareness, type AgentAwarenessState } from "@t3tools/shared/agentAwareness";
import * as DateTime from "effect/DateTime";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * The phone's lock-screen thread card (#1047 part 3): the pure half. The
 * server folds every live thread's awareness (`projectThreadAwareness`, what
 * the T3 Connect relay is fed per thread) into upstream's aggregate card
 * exactly as the relay's `makeAggregateState` does (`infra/relay`, which the
 * server cannot import), with two differences: the title is `PRODUCT_NAME`,
 * and a starting or running row carries its turn's `startedAt` (Infi4's
 * ruling), which the Mac forwards untouched. The card goes to the Mac as the
 * `push` verb's stdin payload `{kind: "thread.activity", state}`, `null`
 * ending it.
 */

/**
 * Upstream's `RelayAgentActivityAggregateRow` plus the fork's `startedAt`.
 * Plain strings where upstream demands non-empty ones: one thread with an
 * odd title must not throw the whole card away — the Mac checks the card's
 * own fields and forwards the rows as they are.
 */
const ThreadActivityRow = Schema.Struct({
  environmentId: EnvironmentId,
  threadId: ThreadId,
  projectTitle: Schema.String,
  threadTitle: Schema.String,
  modelTitle: Schema.String,
  phase: RelayAgentAwarenessPhase,
  status: Schema.String,
  updatedAt: Schema.String,
  deepLink: Schema.String,
  /** The turn's start, on a starting or running row only (fork, #1047). */
  startedAt: Schema.optional(Schema.String),
});
export type ThreadActivityRow = typeof ThreadActivityRow.Type;

/** Upstream's `RelayAgentActivityAggregateState` with the fork's row. */
const ThreadActivityState = Schema.Struct({
  title: Schema.String,
  subtitle: Schema.String,
  activeCount: Schema.Int,
  updatedAt: Schema.String,
  activities: Schema.Array(ThreadActivityRow),
});
export type ThreadActivityState = typeof ThreadActivityState.Type;

const ThreadActivityPush = Schema.Struct({
  kind: Schema.Literal("thread.activity"),
  state: Schema.NullOr(ThreadActivityState),
});
const encodePush = Schema.encodeSync(Schema.fromJsonString(ThreadActivityPush));

/** The `push` request line's `secret` field: the JSON the Mac reads from stdin. */
export function threadActivityPayload(state: ThreadActivityState | null): string {
  return encodePush({ kind: "thread.activity", state });
}

/**
 * The verb, on a build whose push summary names the card (#1086: "the
 * phone's lock-screen thread card"). Older builds list `push` for the phase
 * push only and would refuse the kind; the gate keeps them quiet.
 */
export function manifestHasThreadActivityPush(
  commands: ReadonlyArray<InfinitusManifestCommand>,
): boolean {
  return commands.some(
    (command) =>
      command.name === "push" &&
      command.stdin === "payload" &&
      command.summary.includes("thread.activity"),
  );
}

// --- the relay's fold, ported (infra/relay/src/agentActivity) ---

type Phase = typeof RelayAgentAwarenessPhase.Type;

const RUNNING_ROW_TTL_MS = 2 * 60 * 60 * 1_000;
const WAITING_ROW_TTL_MS = 24 * 60 * 60 * 1_000;
/** How long a finished thread keeps its Done/Failed row on the card. */
export const TERMINAL_DISPLAY_TTL_MS = 15 * 60 * 1_000;
const MAX_ACTIVITY_ROWS = 5;
const MAX_SUMMARY_TEXT_LENGTH = 120;
const MAX_STATUS_TEXT_LENGTH = 40;
const MAX_DEEP_LINK_LENGTH = 512;

function statusForPhase(phase: Phase): string {
  switch (phase) {
    case "waiting_for_approval":
      return "Approval";
    case "waiting_for_input":
      return "Input";
    case "completed":
      return "Done";
    case "failed":
      return "Failed";
    case "starting":
      return "Connecting";
    case "running":
      return "Working";
    case "stale":
      return "Waiting";
  }
}

function phasePriority(phase: Phase): number {
  if (phase === "waiting_for_approval" || phase === "waiting_for_input") return 0;
  if (phase === "failed") return 1;
  if (phase === "starting" || phase === "running") return 2;
  return 3;
}

function isTerminalPhase(phase: Phase): boolean {
  return phase === "completed" || phase === "failed";
}

function epochMs(iso: string): number {
  return Option.match(DateTime.make(iso), {
    onNone: () => Number.NaN,
    onSome: (dt) => dt.epochMilliseconds,
  });
}

function isExpired(state: AgentAwarenessState, nowMs: number): boolean {
  const updatedAtMs = epochMs(state.updatedAt);
  if (Number.isNaN(updatedAtMs)) return true;
  const ttl =
    state.phase === "running" || state.phase === "starting"
      ? RUNNING_ROW_TTL_MS
      : WAITING_ROW_TTL_MS;
  return nowMs >= updatedAtMs + ttl;
}

function isRecentTerminal(state: AgentAwarenessState, nowMs: number): boolean {
  if (!isTerminalPhase(state.phase)) return false;
  const updatedAtMs = epochMs(state.updatedAt);
  if (Number.isNaN(updatedAtMs)) return false;
  return nowMs - updatedAtMs <= TERMINAL_DISPLAY_TTL_MS;
}

function truncateText(text: string, maxLength: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= maxLength) return trimmed;
  return `${trimmed.slice(0, Math.max(0, maxLength - 3)).trimEnd()}...`;
}

function sanitizeDeepLink(deepLink: string): string {
  const trimmed = deepLink.trim();
  if (!trimmed.startsWith("/") || trimmed.startsWith("//")) return "/";
  return truncateText(trimmed, MAX_DEEP_LINK_LENGTH);
}

/** One thread's awareness plus what the fork adds to its row. */
export interface ThreadActivityInput {
  readonly state: AgentAwarenessState;
  /** The latest turn's `startedAt`, carried on a starting or running row. */
  readonly startedAt: string | null;
}

function row(input: ThreadActivityInput): ThreadActivityRow {
  const { state } = input;
  const startedAt =
    input.startedAt !== null && (state.phase === "starting" || state.phase === "running")
      ? { startedAt: input.startedAt }
      : {};
  return {
    environmentId: state.environmentId,
    threadId: state.threadId,
    projectTitle: truncateText(state.projectTitle, MAX_SUMMARY_TEXT_LENGTH),
    threadTitle: truncateText(state.threadTitle, MAX_SUMMARY_TEXT_LENGTH),
    modelTitle: truncateText(state.modelTitle, MAX_SUMMARY_TEXT_LENGTH),
    phase: state.phase,
    status: truncateText(statusForPhase(state.phase), MAX_STATUS_TEXT_LENGTH),
    updatedAt: state.updatedAt,
    deepLink: sanitizeDeepLink(state.deepLink),
    ...startedAt,
  };
}

const newestFirst = (a: ThreadActivityInput, b: ThreadActivityInput) =>
  b.state.updatedAt.localeCompare(a.state.updatedAt);

/**
 * The relay's `makeAggregateState` over every live thread: the active rows
 * by priority (approval, input, failed, working), then the threads finished
 * within `TERMINAL_DISPLAY_TTL_MS`, five rows at most; with nothing active
 * the recent finishes alone (subtitle by the newest); null when there is
 * nothing to show, which ends the card.
 */
export function threadActivityState(
  inputs: ReadonlyArray<ThreadActivityInput>,
  nowMs: number,
): ThreadActivityState | null {
  const active = inputs.filter(
    (input) => !isTerminalPhase(input.state.phase) && !isExpired(input.state, nowMs),
  );
  const recentTerminal = inputs
    .filter((input) => isRecentTerminal(input.state, nowMs))
    .sort(newestFirst);
  if (active.length === 0) {
    const newest = recentTerminal[0];
    if (newest === undefined) return null;
    return {
      title: PRODUCT_NAME,
      subtitle: newest.state.phase === "failed" ? "Agent work failed" : "Agent work completed",
      activeCount: 0,
      updatedAt: newest.state.updatedAt,
      activities: recentTerminal.slice(0, MAX_ACTIVITY_ROWS).map(row),
    };
  }
  const displayed = [
    ...active
      .toSorted((a, b) => phasePriority(a.state.phase) - phasePriority(b.state.phase))
      .slice(0, MAX_ACTIVITY_ROWS),
    ...recentTerminal,
  ].slice(0, MAX_ACTIVITY_ROWS);
  const updatedAt = [...active, ...recentTerminal].reduce((latest, input) =>
    input.state.updatedAt.localeCompare(latest.state.updatedAt) > 0 ? input : latest,
  ).state.updatedAt;
  return {
    title: PRODUCT_NAME,
    subtitle: "Agent work in progress",
    activeCount: active.length,
    updatedAt,
    activities: displayed.map(row),
  };
}

/**
 * When a displayed Done/Failed row ages out, epoch ms — the one moment the
 * card changes with no thread event to announce it — or null when none is
 * shown.
 */
export function nextTerminalExpiryMs(state: ThreadActivityState | null): number | null {
  if (state === null) return null;
  let earliest: number | null = null;
  for (const activity of state.activities) {
    if (!isTerminalPhase(activity.phase)) continue;
    const at = epochMs(activity.updatedAt) + TERMINAL_DISPLAY_TTL_MS + 1;
    if (Number.isNaN(at)) continue;
    earliest = earliest === null ? at : Math.min(earliest, at);
  }
  return earliest;
}

/** Every live thread of the shell snapshot as the fold's input; side questions (#269 C) stay off the phone. */
export function threadActivityInputs(
  environmentId: EnvironmentId,
  snapshot: Pick<OrchestrationShellSnapshot, "projects" | "threads">,
): ReadonlyArray<ThreadActivityInput> {
  const projects = new Map(snapshot.projects.map((project) => [project.id, project]));
  const inputs: Array<ThreadActivityInput> = [];
  for (const thread of snapshot.threads) {
    if (thread.sideOf != null) continue;
    const project = projects.get(thread.projectId);
    if (project === undefined) continue;
    const state = projectThreadAwareness({ environmentId, project, thread });
    if (state === null) continue;
    inputs.push({ state, startedAt: thread.latestTurn?.startedAt ?? null });
  }
  return inputs;
}

const IdentityRow = Schema.Struct({
  ...ThreadActivityRow.fields,
  updatedAt: Schema.optional(Schema.String),
});
const encodeIdentity = Schema.encodeSync(
  Schema.fromJsonString(
    Schema.Struct({
      title: Schema.String,
      subtitle: Schema.String,
      activeCount: Schema.Int,
      activities: Schema.Array(IdentityRow),
    }),
  ),
);

/**
 * What a change of card means: everything but the timestamps, which move on
 * every message (`AgentAwarenessRelay`'s `agentAwarenessPublishIdentity`,
 * one level deeper). Two cards with one identity are one push.
 */
export function threadActivityIdentity(state: ThreadActivityState | null): string {
  if (state === null) return "null";
  const { updatedAt: _updatedAt, activities, ...rest } = state;
  return encodeIdentity({
    ...rest,
    activities: activities.map(({ updatedAt: _rowUpdatedAt, ...activity }) => activity),
  });
}

/** The 5 s the fold waits after a thread event so a burst is one push (the relay's cadence). */
export const COALESCE_MS = 5_000;
