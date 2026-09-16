import type { EnvironmentThreadShell } from "@infinitus/client-runtime/state/shell";
import {
  EnvironmentId,
  ProjectId,
  ProviderInstanceId,
  ThreadId,
  type OrchestrationSession,
} from "@infinitus/contracts";
import { describe, expect, it } from "vite-plus/test";

import { resolveThreadStatus } from "./threadPresentation";

const threadId = ThreadId.make("thread-1");

function makeThread(input: Partial<EnvironmentThreadShell> = {}): EnvironmentThreadShell {
  return {
    id: threadId,
    title: "Thread",
    environmentId: EnvironmentId.make("environment-1"),
    projectId: ProjectId.make("project-1"),
    modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" },
    runtimeMode: "full-access",
    interactionMode: "default",
    branch: null,
    worktreePath: null,
    pullRequests: [],
    latestTurn: null,
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    archivedAt: null,
    settledOverride: null,
    settledAt: null,
    session: null,
    latestUserMessageAt: null,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    hasActionableProposedPlan: false,
    ...input,
  };
}

function makeSession(status: OrchestrationSession["status"]): OrchestrationSession {
  return {
    threadId,
    status,
    providerName: "Codex",
    providerInstanceId: ProviderInstanceId.make("codex"),
    runtimeMode: "full-access",
    activeTurnId: null,
    lastError: status === "error" ? "boom" : null,
    updatedAt: "2026-06-02T00:00:00.000Z",
  };
}

describe("resolveThreadStatus", () => {
  it("says nothing for a settled thread with no background work", () => {
    expect(resolveThreadStatus(makeThread())).toBeNull();
  });

  it("reads watch loops left after the turn as a calm Monitoring", () => {
    const status = resolveThreadStatus(makeThread({ backgroundLiveness: "monitoring" }));
    expect(status?.kind).toBe("monitoring");
    expect(status?.label).toBe("Monitoring");
    expect(status?.pulse).toBe(false);
  });

  it("reads subagent fleets left after the turn as Working", () => {
    const status = resolveThreadStatus(makeThread({ backgroundLiveness: "working" }));
    expect(status?.kind).toBe("working");
    expect(status?.pulse).toBe(true);
  });

  it("keeps a failed session ahead of lingering background work", () => {
    const status = resolveThreadStatus(
      makeThread({ backgroundLiveness: "monitoring", session: makeSession("error") }),
    );
    expect(status?.kind).toBe("error");
  });
});
