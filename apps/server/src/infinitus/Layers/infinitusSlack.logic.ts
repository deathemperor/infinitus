import {
  ApprovalRequestId,
  ProjectId,
  ThreadId,
  type OrchestrationProjectShell,
  type ProviderApprovalDecision,
  type RuntimeMode,
} from "@t3tools/contracts";
import * as Schema from "effect/Schema";

/**
 * Slack bridge (#574): the pure half. A mention is `@Infinitus <project> [build] <task>`;
 * the first word names the project (id, title or folder, like the desktop's
 * deep links), `build` picks auto-accept-edits over the default
 * approval-required mode, the rest is the task. Every post back is a
 * milestone line; the buttons carry their target in the action id.
 */

/** A message's mention tokens (`<@U123>`, `<@U123|name>`) stripped, whitespace folded. */
function stripMentions(text: string): string {
  return text
    .replace(/<@[A-Z0-9]+(?:\|[^>]*)?>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** The two modes a mention can pick; `full-access` never. */
export type SlackRuntimeMode = Extract<RuntimeMode, "approval-required" | "auto-accept-edits">;

export interface SlackMention {
  readonly projectHandle: string;
  readonly runtimeMode: SlackRuntimeMode;
  readonly task: string;
}

export function parseMention(text: string): SlackMention | null {
  const words = stripMentions(text).split(" ");
  const projectHandle = words[0];
  if (projectHandle === undefined || projectHandle.length === 0) return null;
  let rest = words.slice(1);
  let runtimeMode: SlackRuntimeMode = "approval-required";
  if (rest[0]?.toLowerCase() === "build") {
    runtimeMode = "auto-accept-edits";
    rest = rest.slice(1);
  }
  const task = rest.join(" ").trim();
  if (task.length === 0) return null;
  return { projectHandle, runtimeMode, task };
}

function workspaceRootBasename(workspaceRoot: string): string {
  const parts = workspaceRoot.split(/[\\/]+/).filter((part) => part.length > 0);
  return parts[parts.length - 1] ?? workspaceRoot;
}

/** The web's `resolveDeepLinkProject` (deepLink.logic.ts): id, then title, then folder, case-insensitive. */
export function resolveSlackProject(
  projects: ReadonlyArray<OrchestrationProjectShell>,
  handle: string,
): OrchestrationProjectShell | null {
  const wanted = handle.toLowerCase();
  return (
    projects.find((project) => project.id.toLowerCase() === wanted) ??
    projects.find((project) => project.title.toLowerCase() === wanted) ??
    projects.find(
      (project) => workspaceRootBasename(project.workspaceRoot).toLowerCase() === wanted,
    ) ??
    null
  );
}

/** One reply naming the folders a mention can start with. */
export function projectsReply(projects: ReadonlyArray<OrchestrationProjectShell>): string {
  if (projects.length === 0) return "No project to start in: add one in Infinitus first.";
  const names = projects.map((project) => `\`${workspaceRootBasename(project.workspaceRoot)}\``);
  return `Which project? Start with one of: ${names.join(", ")}.`;
}

const MAX_SLACK_TITLE_LENGTH = 80;

export function threadTitle(task: string): string {
  const line = task.split(/\r?\n/, 1)[0]?.trim() ?? "";
  if (line.length === 0) return "Slack task";
  return line.length > MAX_SLACK_TITLE_LENGTH
    ? `${line.slice(0, MAX_SLACK_TITLE_LENGTH - 1)}…`
    : line;
}

export type ReplyCommand =
  | { readonly kind: "stop" }
  | { readonly kind: "babysit" }
  | { readonly kind: "message"; readonly text: string };

export function replyCommand(text: string): ReplyCommand | null {
  const clean = stripMentions(text);
  if (clean.length === 0) return null;
  const word = clean.toLowerCase();
  if (word === "stop") return { kind: "stop" };
  if (word === "babysit") return { kind: "babysit" };
  return { kind: "message", text: clean };
}

// ---------------------------------------------------------------------------
// Buttons: the target rides in the action id, the choice in the value.

const ACTION_PREFIX = "infinitus";

export type SlackAction =
  | {
      readonly kind: "approval";
      readonly threadId: ThreadId;
      readonly requestId: ApprovalRequestId;
      readonly decision: ProviderApprovalDecision;
    }
  | {
      readonly kind: "answer";
      readonly threadId: ThreadId;
      readonly requestId: ApprovalRequestId;
      readonly questionId: string;
      readonly answer: string;
    };

const DECISIONS: ReadonlySet<string> = new Set(["accept", "acceptForSession", "decline"]);

/** `infinitus:approval:<threadId>:<requestId>` / `infinitus:answer:<threadId>:<requestId>:<questionId>`. */
export function parseAction(actionId: string, value: string): SlackAction | null {
  const parts = actionId.split(":");
  if (parts[0] !== ACTION_PREFIX) return null;
  const [, kind, threadId, requestId, ...rest] = parts;
  if (!threadId || !requestId) return null;
  if (kind === "approval") {
    if (!DECISIONS.has(value)) return null;
    return {
      kind,
      threadId: ThreadId.make(threadId),
      requestId: ApprovalRequestId.make(requestId),
      decision: value as ProviderApprovalDecision,
    };
  }
  if (kind === "answer") {
    const questionId = rest.join(":");
    if (questionId.length === 0) return null;
    return {
      kind,
      threadId: ThreadId.make(threadId),
      requestId: ApprovalRequestId.make(requestId),
      questionId,
      answer: value,
    };
  }
  return null;
}

function button(text: string, actionId: string, value: string, style?: "primary" | "danger") {
  return {
    type: "button",
    text: { type: "plain_text", text },
    action_id: actionId,
    value,
    ...(style ? { style } : {}),
  };
}

export interface SlackMessage {
  readonly text: string;
  readonly blocks?: ReadonlyArray<unknown>;
}

const MAX_DETAIL_LENGTH = 300;

function bounded(value: string, max: number): string {
  const flat = value.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

export function approvalMessage(input: {
  readonly threadId: ThreadId;
  readonly requestId: ApprovalRequestId;
  readonly requestType: string;
  readonly detail?: string | undefined;
}): SlackMessage {
  const actionId = `${ACTION_PREFIX}:approval:${input.threadId}:${input.requestId}`;
  const what = input.detail ? bounded(input.detail, MAX_DETAIL_LENGTH) : input.requestType;
  const text = `Approval needed: ${what}`;
  return {
    text,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text } },
      {
        type: "actions",
        elements: [
          button("Approve", actionId, "accept", "primary"),
          button("Approve for this session", actionId, "acceptForSession"),
          button("Deny", actionId, "decline", "danger"),
        ],
      },
    ],
  };
}

export function questionMessage(input: {
  readonly threadId: ThreadId;
  readonly requestId: ApprovalRequestId;
  readonly questions: ReadonlyArray<{
    readonly id: string;
    readonly question: string;
    readonly options: ReadonlyArray<{
      readonly label: string;
      readonly value?: string | undefined;
    }>;
  }>;
}): SlackMessage {
  const first = input.questions[0];
  if (first === undefined) return { text: "The agent has a question; answer it in Infinitus." };
  const actionId = `${ACTION_PREFIX}:answer:${input.threadId}:${input.requestId}:${first.id}`;
  const text = `Question: ${bounded(first.question, MAX_DETAIL_LENGTH)}`;
  const options = first.options.slice(0, 5);
  return {
    text,
    blocks: [
      { type: "section", text: { type: "mrkdwn", text } },
      ...(options.length > 0
        ? [
            {
              type: "actions",
              elements: options.map((option) =>
                button(bounded(option.label, 75), actionId, option.value ?? option.label),
              ),
            },
          ]
        : []),
    ],
  };
}

export const MAX_DONE_TEXT_LENGTH = 1500;

/** The done post: the last assistant message trimmed, then the PR link when there is one. */
export function doneText(input: {
  readonly state: "completed" | "error";
  readonly assistantText: string | null;
  readonly pullRequestUrl: string | null;
}): string {
  const head = input.state === "completed" ? "Done." : "Failed.";
  const body = input.assistantText?.trim() ?? "";
  const cut =
    body.length > MAX_DONE_TEXT_LENGTH ? `${body.slice(0, MAX_DONE_TEXT_LENGTH - 1)}…` : body;
  return [
    head,
    ...(cut.length > 0 ? [cut] : []),
    ...(input.pullRequestUrl ? [`PR: ${input.pullRequestUrl}`] : []),
  ].join("\n");
}

/** Fixed lines per fork activity kind; the row's summary can name an account, so it never travels. */
export function activityLine(kind: string): string | null {
  switch (kind) {
    case "infinitus.thread.limited":
      return "Stopped on a usage limit; resumes when an account is free.";
    case "infinitus.thread.held":
      return "Waiting for headroom.";
    case "infinitus.thread.released":
      return "Released; running.";
    case "infinitus.thread.paused":
      return "Paused for headroom.";
    case "infinitus.thread.resumed":
    case "infinitus.turn.resumed":
      return "Resumed.";
    case "babysit.done":
      return "Babysit done: the PR merged.";
    case "babysit.stopped":
      return "Babysit stopped: the PR still needs work.";
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Bindings: a Slack thread ↔ an Infinitus thread, kept across restarts.

export const SlackThreadBinding = Schema.Struct({
  channel: Schema.String,
  threadTs: Schema.String,
  threadId: ThreadId,
  projectId: ProjectId,
  /** The mode the mention picked; a reply's turn keeps it. */
  runtimeMode: Schema.Literals(["approval-required", "auto-accept-edits"]),
  createdAt: Schema.String,
});
export type SlackThreadBinding = typeof SlackThreadBinding.Type;

export const SlackThreadBindings = Schema.Array(SlackThreadBinding);

export const MAX_SLACK_BINDINGS = 500;

export function slackThreadKey(channel: string, threadTs: string): string {
  return `${channel}:${threadTs}`;
}
