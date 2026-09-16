import { describe, expect, it } from "vite-plus/test";
import { ThreadId, TurnId, type OrchestrationThreadShell } from "@infinitus/contracts";

import {
  bestOfMemberChanges,
  bestOfMemberStats,
  bestOfMemberStatus,
  bestOfMemberTitle,
  bestOfSiblings,
  planBestOfMembers,
} from "./bestOf.logic";

describe("planBestOfMembers (#269 B)", () => {
  const first = ThreadId.make("draft-1");
  let minted = 0;
  const newThreadId = () => ThreadId.make(`minted-${++minted}`);

  it("keeps the draft's id for the first member and mints the rest, one group", () => {
    minted = 0;
    const members = planBestOfMembers({
      firstThreadId: first,
      chips: [
        { model: "opus", label: "Opus" },
        { model: "sonnet", label: "Sonnet" },
        { model: "opus", label: "Opus again" },
      ],
      title: "Fix login",
      groupId: "g1",
      newThreadId,
    });
    expect(members).toEqual([
      { threadId: "draft-1", groupId: "g1", model: "opus", title: "Fix login · Opus" },
      { threadId: "minted-1", groupId: "g1", model: "sonnet", title: "Fix login · Sonnet" },
    ]);
    expect(bestOfMemberTitle("T", "L")).toBe("T · L");
  });

  it("is not a bake-off below two distinct models or above four", () => {
    expect(
      planBestOfMembers({
        firstThreadId: first,
        chips: [{ model: "opus", label: "Opus" }],
        title: "T",
        groupId: "g",
        newThreadId,
      }),
    ).toBeNull();
    expect(
      planBestOfMembers({
        firstThreadId: first,
        chips: ["a", "b", "c", "d", "e"].map((model) => ({ model, label: model })),
        title: "T",
        groupId: "g",
        newThreadId,
      }),
    ).toBeNull();
  });
});

function shell(
  id: string,
  overrides: Partial<
    Pick<
      OrchestrationThreadShell,
      | "groupId"
      | "archivedAt"
      | "createdAt"
      | "session"
      | "latestTurn"
      | "hasPendingApprovals"
      | "hasPendingUserInput"
    >
  > = {},
) {
  return {
    id: ThreadId.make(id),
    groupId: "g1",
    archivedAt: null,
    createdAt: "2026-09-12T00:00:00.000Z",
    session: null,
    latestTurn: null,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    ...overrides,
  };
}

describe("bestOfSiblings", () => {
  it("lists the live members of the group, oldest first", () => {
    const rows = [
      shell("c", { createdAt: "2026-09-12T00:00:02.000Z" }),
      shell("a"),
      shell("kept-away", { archivedAt: "2026-09-12T01:00:00.000Z" }),
      shell("other", { groupId: "g2" }),
      shell("b", { createdAt: "2026-09-12T00:00:01.000Z" }),
    ];
    expect(bestOfSiblings(rows, "g1").map((row) => row.id)).toEqual(["a", "b", "c"]);
  });
});

describe("bestOfMemberStatus", () => {
  const turn = (state: "running" | "completed" | "error" | "interrupted") => ({
    turnId: TurnId.make("t"),
    state,
    requestedAt: "2026-09-12T00:00:00.000Z",
    startedAt: null,
    completedAt: null,
    assistantMessageId: null,
  });

  it("ranks a pending approval or question over the turn state", () => {
    expect(bestOfMemberStatus(shell("a", { hasPendingApprovals: true }))).toBe("waiting-approval");
    expect(bestOfMemberStatus(shell("a", { hasPendingUserInput: true }))).toBe("waiting-input");
    expect(bestOfMemberStatus(shell("a", { latestTurn: turn("running") }))).toBe("running");
    expect(bestOfMemberStatus(shell("a", { latestTurn: turn("completed") }))).toBe("done");
    expect(bestOfMemberStatus(shell("a", { latestTurn: turn("error") }))).toBe("failed");
    expect(bestOfMemberStatus(shell("a", { latestTurn: turn("interrupted") }))).toBe("stopped");
    expect(bestOfMemberStatus(shell("a"))).toBe("running");
  });
});

describe("bestOfMemberStats (#269 B)", () => {
  const usage = {
    source: "runtime" as const,
    turns: 3,
    inputTokens: 0,
    outputTokens: 0,
    cachedInputTokens: 0,
    cacheCreationTokens: 0,
    reasoningTokens: 0,
    subagentTurns: 0,
    costUsd: null,
    models: [],
    lastTurnAt: "2026-09-12T00:00:00.000Z",
    toolCalls: 12,
    durationMs: 250_000,
  };

  it("reads turns, tool calls and wall time off the thread's usage rollup", () => {
    expect(bestOfMemberStats(usage)).toBe("3 turns · 12 tool calls · 4m 10s");
    expect(bestOfMemberStats({ ...usage, turns: 1, toolCalls: 1, durationMs: 900 })).toBe(
      "1 turn · 1 tool call · 900ms",
    );
  });

  it("leaves out what the rollup does not carry, and says nothing before a turn", () => {
    const { toolCalls: _toolCalls, durationMs: _durationMs, ...bare } = usage;
    expect(bestOfMemberStats(bare)).toBe("3 turns");
    expect(bestOfMemberStats({ ...usage, turns: 0 })).toBeNull();
    expect(bestOfMemberStats(undefined)).toBeNull();
  });
});

describe("bestOfMemberChanges (#269 B)", () => {
  it("sums the working tree into files and lines", () => {
    expect(
      bestOfMemberChanges({
        hasWorkingTreeChanges: true,
        workingTree: {
          files: [
            { path: "a.ts", insertions: 40, deletions: 7 },
            { path: "b.ts", insertions: 2, deletions: 0 },
          ],
          insertions: 42,
          deletions: 7,
        },
      }),
    ).toBe("2 files, +42 −7");
    expect(
      bestOfMemberChanges({
        hasWorkingTreeChanges: true,
        workingTree: {
          files: [{ path: "a.ts", insertions: 0, deletions: 1 }],
          insertions: 0,
          deletions: 1,
        },
      }),
    ).toBe("1 file, +0 −1");
  });

  it("is null before the status arrives and while the tree is clean", () => {
    expect(bestOfMemberChanges(null)).toBeNull();
    expect(
      bestOfMemberChanges({
        hasWorkingTreeChanges: false,
        workingTree: { files: [], insertions: 0, deletions: 0 },
      }),
    ).toBeNull();
  });
});
