import { describe, expect, it } from "vite-plus/test";

import { worktreeCapRefusal } from "./worktreeCap.logic.ts";

describe("worktreeCapRefusal (#269 H)", () => {
  it("allows a worktree under the limit or with the limit off", () => {
    expect(worktreeCapRefusal({ count: 24, oldestArchived: [] }, 25)).toBeNull();
    expect(worktreeCapRefusal({ count: 400, oldestArchived: [] }, 0)).toBeNull();
  });

  it("counts the worktrees other bootstraps are creating right now", () => {
    expect(worktreeCapRefusal({ count: 23, oldestArchived: [] }, 25, 1)).toBeNull();
    expect(worktreeCapRefusal({ count: 23, oldestArchived: [] }, 25, 2)).toContain(
      "25 of 25 threads",
    );
  });

  it("refuses at the limit and names the oldest archived holders, bounded to one line", () => {
    const refusal = worktreeCapRefusal(
      {
        count: 25,
        oldestArchived: [
          { title: "  spike\n\nretry ", archivedAt: "2026-09-01T00:00:00.000Z" },
          { title: "x".repeat(60), archivedAt: "2026-09-02T00:00:00.000Z" },
          { title: "", archivedAt: "2026-09-03T00:00:00.000Z" },
        ],
      },
      25,
    );
    expect(refusal).toBe(
      `Worktree limit reached: 25 of 25 threads hold a worktree. Delete an archived thread to free its worktree (oldest: “spike retry”, “${"x".repeat(39)}…”, “Untitled”), or raise the Worktree limit in the server's settings.`,
    );
    expect(refusal).not.toContain("\n");
  });

  it("points at deleting a thread when no archived thread holds one", () => {
    expect(worktreeCapRefusal({ count: 26, oldestArchived: [] }, 25)).toBe(
      "Worktree limit reached: 26 of 25 threads hold a worktree. Delete a thread you no longer need to free its worktree, or raise the Worktree limit in the server's settings.",
    );
  });
});
