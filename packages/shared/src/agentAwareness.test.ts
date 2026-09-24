import { describe, expect, it } from "@effect/vitest";

import type {
  EnvironmentId,
  OrchestrationProjectShell,
  OrchestrationThreadShell,
  ThreadId,
  TurnId,
} from "@infinitus/contracts";
import { ProviderInstanceId } from "@infinitus/contracts";

import { projectThreadAwareness } from "./agentAwareness.ts";

const NOW = "2026-05-22T12:00:00.000Z";

const project = {
  title: "t3code",
} satisfies Pick<OrchestrationProjectShell, "title">;

function thread(
  overrides: Partial<OrchestrationThreadShell> = {},
): Pick<
  OrchestrationThreadShell,
  | "id"
  | "title"
  | "modelSelection"
  | "session"
  | "latestTurn"
  | "updatedAt"
  | "hasPendingApprovals"
  | "hasPendingUserInput"
  | "backgroundLiveness"
> {
  return {
    id: "thread-1" as ThreadId,
    title: "Fix failing CI",
    modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" },
    session: null,
    latestTurn: null,
    updatedAt: NOW,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    ...overrides,
  };
}

describe("projectThreadAwareness", () => {
  it("returns null for idle threads without an active awareness state", () => {
    expect(
      projectThreadAwareness({
        environmentId: "env-1" as EnvironmentId,
        project,
        thread: thread(),
      }),
    ).toBeNull();
  });

  it("prioritizes approval requests over running state", () => {
    const state = projectThreadAwareness({
      environmentId: "env-1" as EnvironmentId,
      project,
      thread: thread({
        hasPendingApprovals: true,
        session: {
          threadId: "thread-1" as ThreadId,
          status: "running",
          providerName: "Codex",
          runtimeMode: "full-access",
          activeTurnId: "turn-1" as TurnId,
          lastError: null,
          updatedAt: NOW,
        },
      }),
    });

    expect(state?.phase).toBe("waiting_for_approval");
    expect(state?.headline).toBe("Approval needed");
  });

  it("projects running provider sessions", () => {
    const state = projectThreadAwareness({
      environmentId: "env-1" as EnvironmentId,
      project,
      thread: thread({
        session: {
          threadId: "thread-1" as ThreadId,
          status: "running",
          providerName: "Codex",
          runtimeMode: "full-access",
          activeTurnId: "turn-1" as TurnId,
          lastError: null,
          updatedAt: NOW,
        },
      }),
    });

    expect(state).toMatchObject({
      phase: "running",
      headline: "Agent is working",
      detail: "Codex is active.",
      modelTitle: "gpt-5.4",
      deepLink: "/threads/env-1/thread-1",
    });
  });

  it("projects completed turns as completed even when teardown settled them as interrupted", () => {
    const finishedTurn = {
      turnId: "turn-1" as TurnId,
      state: "interrupted" as const,
      requestedAt: NOW,
      startedAt: NOW,
      completedAt: NOW,
      assistantMessageId: null,
    };
    const state = projectThreadAwareness({
      environmentId: "env-1" as EnvironmentId,
      project,
      thread: thread({ latestTurn: finishedTurn }),
    });

    // Session teardown settles still-running turns by session status, and
    // that write can race turn.completed; the completion timestamp is the
    // durable signal. Without this the thread resolves to null persistently
    // and gets tombstoned off the lock-screen card instead of showing Done.
    expect(state?.phase).toBe("completed");

    const trulyInterrupted = projectThreadAwareness({
      environmentId: "env-1" as EnvironmentId,
      project,
      thread: thread({ latestTurn: { ...finishedTurn, completedAt: null } }),
    });
    expect(trulyInterrupted).toBeNull();
  });

  it("projects ready sessions with no materialized turn as completed", () => {
    // Quick threads without code changes never get a checkpoint, so the SQL
    // shell has no latestTurn row and latest_turn_id is cleared when the
    // session settles; the ready session is the only completion signal left.
    const state = projectThreadAwareness({
      environmentId: "env-1" as EnvironmentId,
      project,
      thread: thread({
        session: {
          threadId: "thread-1" as ThreadId,
          status: "ready",
          providerName: "Codex",
          runtimeMode: "full-access",
          activeTurnId: null,
          lastError: null,
          updatedAt: NOW,
        },
      }),
    });

    expect(state?.phase).toBe("completed");
  });

  it("keeps a settled thread running while background agents work on", () => {
    // The thread list says Working for a settled turn whose subagents or
    // workflows are still live; the card has to agree, or its active count
    // runs one short and a Done alert rings while work continues.
    const settled = {
      latestTurn: {
        turnId: "turn-1" as TurnId,
        state: "completed" as const,
        requestedAt: NOW,
        startedAt: NOW,
        completedAt: NOW,
        assistantMessageId: null,
      },
    };
    const working = projectThreadAwareness({
      environmentId: "env-1" as EnvironmentId,
      project,
      thread: thread({ ...settled, backgroundLiveness: "working" }),
    });
    expect(working?.phase).toBe("running");

    // A watch loop alone reads Monitoring on the lists, so the card says so
    // too rather than Done.
    const monitoring = projectThreadAwareness({
      environmentId: "env-1" as EnvironmentId,
      project,
      thread: thread({ ...settled, backgroundLiveness: "monitoring" }),
    });
    expect(monitoring?.phase).toBe("monitoring");
    expect(monitoring?.headline).toBe("Agent is monitoring");
  });

  it("projects failures with the session error detail", () => {
    const state = projectThreadAwareness({
      environmentId: "env-1" as EnvironmentId,
      project,
      thread: thread({
        session: {
          threadId: "thread-1" as ThreadId,
          status: "error",
          providerName: "Codex",
          runtimeMode: "full-access",
          activeTurnId: null,
          lastError: "Provider process exited.",
          updatedAt: NOW,
        },
      }),
    });

    expect(state).toMatchObject({
      phase: "failed",
      headline: "Agent failed",
      detail: "Provider process exited.",
    });
  });
});
