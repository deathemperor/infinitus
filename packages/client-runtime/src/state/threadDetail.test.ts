import { describe, expect, it } from "vite-plus/test";

import {
  EnvironmentId,
  MessageId,
  ProjectId,
  ProviderInstanceId,
  QueueId,
  ThreadId,
} from "@t3tools/contracts";
import type { OrchestrationQueuedTurn, OrchestrationThread, OrchestrationThreadShell } from "@t3tools/contracts";

import type { EnvironmentThread, EnvironmentThreadShell } from "./models.ts";
import { mergeEnvironmentThread } from "./threadDetail.ts";

const ENVIRONMENT_ID = EnvironmentId.make("environment-1");
const THREAD_ID = ThreadId.make("thread-1");
const PROJECT_ID = ProjectId.make("project-1");

const BASE_SHELL_FIELDS = {
  id: THREAD_ID,
  projectId: PROJECT_ID,
  title: "Thread",
  modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" },
  runtimeMode: "full-access",
  interactionMode: "default",
  branch: null,
  worktreePath: null,
  latestTurn: null,
  createdAt: "2026-06-01T00:00:00.000Z",
  updatedAt: "2026-06-01T00:00:00.000Z",
  archivedAt: null,
  settledOverride: null,
  settledAt: null,
  pullRequests: [],
  session: null,
  latestUserMessageAt: null,
  hasPendingApprovals: false,
  hasPendingUserInput: false,
  hasActionableProposedPlan: false,
} as const satisfies Omit<OrchestrationThreadShell, "queuedTurns">;

const BASE_DETAIL_FIELDS = {
  ...BASE_SHELL_FIELDS,
  deletedAt: null,
  messages: [],
  proposedPlans: [],
  activities: [],
  checkpoints: [],
} as const satisfies Omit<OrchestrationThread, "queuedTurns">;

const QUEUED_TURN: OrchestrationQueuedTurn = {
  queueId: QueueId.make("queue-1"),
  messageId: MessageId.make("message-1"),
  text: "queued while busy",
  attachments: [],
  orderKey: "a0",
  createdAt: "2026-06-01T00:00:00.000Z",
  updatedAt: "2026-06-01T00:00:00.000Z",
};

function makeShell(overrides: Partial<EnvironmentThreadShell> = {}): EnvironmentThreadShell {
  return { ...BASE_SHELL_FIELDS, environmentId: ENVIRONMENT_ID, ...overrides };
}

function makeDetail(overrides: Partial<EnvironmentThread> = {}): EnvironmentThread {
  return { ...BASE_DETAIL_FIELDS, environmentId: ENVIRONMENT_ID, ...overrides };
}

describe("mergeEnvironmentThread queuedTurns", () => {
  it("picks up a row queued after the detail snapshot was taken", () => {
    const detail = makeDetail();
    const shell = makeShell({ queuedTurns: [QUEUED_TURN] });

    const merged = mergeEnvironmentThread(detail, shell);

    expect(merged?.queuedTurns).toEqual([QUEUED_TURN]);
  });

  it("drops a row that was removed from the queue after the detail snapshot was taken", () => {
    const detail = makeDetail({ queuedTurns: [QUEUED_TURN] });
    const shell = makeShell();

    const merged = mergeEnvironmentThread(detail, shell);

    expect(merged?.queuedTurns).toBeUndefined();
  });

  it("keeps the detail's rows when there is no shell to merge with", () => {
    const detail = makeDetail({ queuedTurns: [QUEUED_TURN] });

    const merged = mergeEnvironmentThread(detail, null);

    expect(merged?.queuedTurns).toEqual([QUEUED_TURN]);
  });
});
