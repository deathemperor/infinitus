import {
  EnvironmentId,
  ProjectId,
  ThreadId,
  type OrchestrationProjectShell,
  type OrchestrationThreadShell,
} from "@t3tools/contracts";
import type { InfinitusManifestCommand } from "@t3tools/contracts/infinitus";
import { PRODUCT_NAME } from "@t3tools/contracts/productName";
import type { AgentAwarenessState } from "@t3tools/shared/agentAwareness";
import * as DateTime from "effect/DateTime";
import { describe, expect, it } from "vite-plus/test";

import {
  manifestHasThreadActivityPush,
  nextTerminalExpiryMs,
  TERMINAL_DISPLAY_TTL_MS,
  threadActivityIdentity,
  threadActivityInputs,
  threadActivityPayload,
  threadActivityState,
  type ThreadActivityInput,
} from "./infinitusAgentActivity.logic.ts";

const environmentId = EnvironmentId.make("env-1");
const projectId = ProjectId.make("project-1");
const NOW = Date.parse("2026-09-13T10:00:00.000Z");
const iso = (offsetMs: number) => DateTime.formatIso(DateTime.makeUnsafe(NOW + offsetMs));

const state = (
  id: string,
  phase: AgentAwarenessState["phase"],
  updatedAt = iso(0),
): AgentAwarenessState => ({
  environmentId,
  threadId: ThreadId.make(id),
  projectTitle: "Acme",
  threadTitle: `Thread ${id}`,
  phase,
  headline: "",
  modelTitle: "opus",
  updatedAt,
  deepLink: `/threads/env-1/${id}`,
});
const input = (
  id: string,
  phase: AgentAwarenessState["phase"],
  updatedAt?: string,
  startedAt: string | null = null,
): ThreadActivityInput => ({ state: state(id, phase, updatedAt), startedAt });

describe("threadActivityState (#1047)", () => {
  it("is null with nothing to show", () => {
    expect(threadActivityState([], NOW)).toBeNull();
    // A finish older than the display window is gone.
    expect(
      threadActivityState([input("a", "completed", iso(-TERMINAL_DISPLAY_TTL_MS - 1))], NOW),
    ).toBeNull();
    // A running row two hours stale is gone too (the relay's row TTL).
    expect(threadActivityState([input("a", "running", iso(-2 * 60 * 60 * 1_000))], NOW)).toBeNull();
  });

  it("ranks active rows approval, input, failed, working and titles the card by the product", () => {
    const card = threadActivityState(
      [
        input("w", "running", iso(-3_000), iso(-30_000)),
        input("f", "failed"),
        // Approval and input share the first rank (the relay's rule): input order holds.
        input("a", "waiting_for_approval"),
        input("i", "waiting_for_input"),
        input("s", "starting", iso(-1_000)),
      ],
      NOW,
    );
    expect(card).toMatchObject({
      title: PRODUCT_NAME,
      subtitle: "Agent work in progress",
      activeCount: 4,
      updatedAt: iso(0),
    });
    expect(card?.activities.map((row) => `${row.threadId}:${row.status}`)).toEqual([
      "a:Approval",
      "i:Input",
      "w:Working",
      "s:Connecting",
      // Failed is terminal: it rides along after the active rows.
      "f:Failed",
    ]);
    // The turn's start rides on the working row only.
    expect(card?.activities.find((row) => row.threadId === "w")?.startedAt).toBe(iso(-30_000));
    expect(card?.activities.find((row) => row.threadId === "a")?.startedAt).toBeUndefined();
  });

  it("caps the card at five rows and stamps the newest time", () => {
    const rows = ["a", "b", "c", "d", "e", "f", "g"].map((id, index) =>
      input(id, "running", iso(-index * 1_000)),
    );
    const card = threadActivityState(rows, NOW);
    expect(card?.activeCount).toBe(7);
    expect(card?.activities).toHaveLength(5);
    expect(card?.updatedAt).toBe(iso(0));
  });

  it("shows the recent finishes alone once nothing runs, newest first, worded by the newest", () => {
    const done = threadActivityState(
      [input("old", "completed", iso(-60_000)), input("new", "completed", iso(-1_000))],
      NOW,
    );
    expect(done).toMatchObject({
      subtitle: "Agent work completed",
      activeCount: 0,
      updatedAt: iso(-1_000),
    });
    expect(done?.activities.map((row) => row.threadId)).toEqual(["new", "old"]);
    const failed = threadActivityState(
      [input("old", "completed", iso(-60_000)), input("new", "failed", iso(-1_000))],
      NOW,
    );
    expect(failed?.subtitle).toBe("Agent work failed");
    // A finished row never carries a start.
    expect(done?.activities[0]?.startedAt).toBeUndefined();
  });

  it("names the moment the earliest shown finish ages out", () => {
    expect(nextTerminalExpiryMs(null)).toBeNull();
    expect(nextTerminalExpiryMs(threadActivityState([input("a", "running")], NOW))).toBeNull();
    const card = threadActivityState(
      [
        input("a", "running"),
        input("b", "completed", iso(-60_000)),
        input("c", "failed", iso(-10_000)),
      ],
      NOW,
    );
    expect(nextTerminalExpiryMs(card)).toBe(NOW - 60_000 + TERMINAL_DISPLAY_TTL_MS + 1);
  });

  it("trims long titles and refuses a deep link that leaves the app", () => {
    const long = { ...state("a", "running"), threadTitle: "x".repeat(200), deepLink: "//evil" };
    const card = threadActivityState([{ state: long, startedAt: null }], NOW);
    expect(card?.activities[0]?.threadTitle).toHaveLength(120);
    expect(card?.activities[0]?.threadTitle.endsWith("...")).toBe(true);
    expect(card?.activities[0]?.deepLink).toBe("/");
  });
});

describe("threadActivityIdentity", () => {
  it("ignores the timestamps at both levels and nothing else", () => {
    const a = threadActivityState([input("a", "running", iso(-1_000))], NOW);
    const b = threadActivityState([input("a", "running", iso(-500))], NOW);
    const c = threadActivityState([input("a", "waiting_for_input", iso(-500))], NOW);
    expect(threadActivityIdentity(a)).toBe(threadActivityIdentity(b));
    expect(threadActivityIdentity(a)).not.toBe(threadActivityIdentity(c));
    expect(threadActivityIdentity(null)).toBe("null");
    // A start moving is a change: the phone draws it.
    const d = threadActivityState([input("a", "running", iso(-500), iso(-2_000))], NOW);
    expect(threadActivityIdentity(b)).not.toBe(threadActivityIdentity(d));
  });
});

describe("threadActivityPayload", () => {
  it("is the push verb's stdin JSON, null ending the card", () => {
    expect(JSON.parse(threadActivityPayload(null))).toEqual({
      kind: "thread.activity",
      state: null,
    });
    const card = threadActivityState([input("a", "running", iso(0), iso(-5_000))], NOW);
    const parsed = JSON.parse(threadActivityPayload(card)) as {
      state: { activities: ReadonlyArray<Record<string, unknown>> };
    };
    expect(parsed).toMatchObject({ kind: "thread.activity", state: { title: PRODUCT_NAME } });
    expect(parsed.state.activities[0]).toMatchObject({
      threadId: "a",
      status: "Working",
      deepLink: "/threads/env-1/a",
      startedAt: iso(-5_000),
    });
  });
});

describe("threadActivityInputs", () => {
  const project = { id: projectId, title: "Acme" } as unknown as OrchestrationProjectShell;
  const shell = (id: string, extra: Record<string, unknown> = {}): OrchestrationThreadShell =>
    ({
      id: ThreadId.make(id),
      projectId,
      title: `Thread ${id}`,
      modelSelection: { instanceId: "claude", model: "opus" },
      session: { activeTurnId: "turn-1", status: "running" },
      latestTurn: {
        turnId: "turn-1",
        state: "running",
        requestedAt: iso(-10_000),
        startedAt: iso(-9_000),
        completedAt: null,
        assistantMessageId: null,
      },
      updatedAt: iso(0),
      hasPendingApprovals: false,
      hasPendingUserInput: false,
      ...extra,
    }) as unknown as OrchestrationThreadShell;

  it("folds every live thread of a known project, skipping side questions", () => {
    const inputs = threadActivityInputs(environmentId, {
      projects: [project],
      threads: [
        shell("a"),
        shell("side", { sideOf: ThreadId.make("a") }),
        shell("orphan", { projectId: ProjectId.make("gone") }),
        shell("quiet", { session: null, latestTurn: null }),
      ],
    });
    expect(inputs.map((row) => row.state.threadId)).toEqual(["a"]);
    expect(inputs[0]).toMatchObject({
      state: { phase: "running", projectTitle: "Acme", deepLink: "/threads/env-1/a" },
      startedAt: iso(-9_000),
    });
  });
});

describe("manifestHasThreadActivityPush", () => {
  const push = (summary: string, stdin?: string): InfinitusManifestCommand => ({
    name: "push",
    args: [],
    options: [],
    effect: "write",
    summary,
    replyShape: "",
    ...(stdin === undefined ? {} : { stdin }),
  });
  it("needs the push verb taking a payload whose summary names the card", () => {
    expect(
      manifestHasThreadActivityPush([push('… {kind: "thread.activity", state} …', "payload")]),
    ).toBe(true);
    // Today's builds: the phase push only.
    expect(
      manifestHasThreadActivityPush([push("…{kind, threadId, title, phase}…", "payload")]),
    ).toBe(false);
    expect(manifestHasThreadActivityPush([push("thread.activity")])).toBe(false);
    expect(manifestHasThreadActivityPush([])).toBe(false);
  });
});
