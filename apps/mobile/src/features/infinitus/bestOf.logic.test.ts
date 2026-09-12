import { ThreadId, type OrchestrationThreadShell } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { bestOfCardShown, bestOfMemberStatus, bestOfSiblings } from "./bestOf.logic";

const shell = (
  id: string,
  createdAt: string,
  groupId: string | null,
  archivedAt: string | null = null,
): Pick<OrchestrationThreadShell, "id" | "groupId" | "archivedAt" | "createdAt"> => ({
  id: ThreadId.make(id),
  createdAt,
  groupId,
  archivedAt,
});

describe("best of N on the phone (#269 B)", () => {
  it("lists a group's live members oldest first and leaves the kept-away ones out", () => {
    const shells = [
      shell("b", "2026-09-12T10:00:01.000Z", "g"),
      shell("a", "2026-09-12T10:00:00.000Z", "g"),
      shell("c", "2026-09-12T10:00:02.000Z", "g", "2026-09-12T11:00:00.000Z"),
      shell("d", "2026-09-12T09:00:00.000Z", "other"),
      shell("e", "2026-09-12T09:00:00.000Z", null),
    ];
    expect(bestOfSiblings(shells, "g").map((s) => s.id)).toEqual(["a", "b"]);
  });

  it("shows the card only while this thread has a live sibling", () => {
    const two = [shell("a", "1", "g"), shell("b", "2", "g")];
    expect(bestOfCardShown(two, "a")).toBe(true);
    expect(bestOfCardShown([shell("a", "1", "g")], "a")).toBe(false);
    expect(bestOfCardShown(two, "z")).toBe(false);
  });

  it("words a member's status with approvals and questions first", () => {
    const base = {
      session: null,
      latestTurn: null,
      hasPendingApprovals: false,
      hasPendingUserInput: false,
    } as unknown as Pick<
      OrchestrationThreadShell,
      "session" | "latestTurn" | "hasPendingApprovals" | "hasPendingUserInput"
    >;
    expect(bestOfMemberStatus({ ...base, hasPendingApprovals: true })).toBe("waiting-approval");
    expect(bestOfMemberStatus({ ...base, hasPendingUserInput: true })).toBe("waiting-input");
    expect(bestOfMemberStatus(base)).toBe("running");
    expect(
      bestOfMemberStatus({
        ...base,
        session: { status: "starting" } as OrchestrationThreadShell["session"],
      }),
    ).toBe("starting");
    const turn = (state: "running" | "completed" | "error" | "interrupted") =>
      ({ state }) as unknown as OrchestrationThreadShell["latestTurn"];
    expect(bestOfMemberStatus({ ...base, latestTurn: turn("running") })).toBe("running");
    expect(bestOfMemberStatus({ ...base, latestTurn: turn("completed") })).toBe("done");
    expect(bestOfMemberStatus({ ...base, latestTurn: turn("error") })).toBe("failed");
    expect(bestOfMemberStatus({ ...base, latestTurn: turn("interrupted") })).toBe("stopped");
  });
});
