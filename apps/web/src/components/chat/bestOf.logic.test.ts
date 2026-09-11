import { describe, expect, it } from "vite-plus/test";
import { ThreadId, TurnId, type OrchestrationThreadShell } from "@t3tools/contracts";

import {
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
