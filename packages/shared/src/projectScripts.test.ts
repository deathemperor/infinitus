import { describe, expect, it } from "vite-plus/test";

import {
  PROJECT_SCRIPT_PORT_BLOCK_SIZE,
  projectScriptPortBlock,
  projectScriptRuntimeEnv,
} from "./projectScripts.js";

describe("projectScriptPortBlock (#270 J)", () => {
  it("is stable for a path and ten ports wide", () => {
    const block = projectScriptPortBlock("/repo/.worktrees/feature-a");
    expect(projectScriptPortBlock("/repo/.worktrees/feature-a")).toEqual(block);
    expect(block.end - block.start + 1).toBe(PROJECT_SCRIPT_PORT_BLOCK_SIZE);
    expect(block.start % PROJECT_SCRIPT_PORT_BLOCK_SIZE).toBe(0);
  });

  it("stays below the ephemeral range and above the usual defaults", () => {
    for (const path of ["/a", "/repo", "C:\\code\\x", "/very/long/path/".repeat(8), ""]) {
      const block = projectScriptPortBlock(path);
      expect(block.start).toBeGreaterThanOrEqual(10_000);
      expect(block.end).toBeLessThan(30_000);
    }
  });

  it("gives sibling worktrees different blocks and ignores a trailing separator", () => {
    const a = projectScriptPortBlock("/repo/.worktrees/a");
    const b = projectScriptPortBlock("/repo/.worktrees/b");
    expect(a).not.toEqual(b);
    expect(projectScriptPortBlock("/repo/.worktrees/a/")).toEqual(a);
    expect(projectScriptPortBlock("C:\\repo\\wt\\")).toEqual(
      projectScriptPortBlock("C:\\repo\\wt"),
    );
  });
});

describe("projectScriptRuntimeEnv ports (#270 J)", () => {
  it("derives the block from the worktree, else the project root", () => {
    const worktree = projectScriptPortBlock("/repo/.worktrees/a");
    const root = projectScriptPortBlock("/repo");
    expect(
      projectScriptRuntimeEnv({ project: { cwd: "/repo" }, worktreePath: "/repo/.worktrees/a" }),
    ).toMatchObject({ T3CODE_PORT: String(worktree.start), T3CODE_PORT_END: String(worktree.end) });
    expect(
      projectScriptRuntimeEnv({ project: { cwd: "/repo" }, worktreePath: null }),
    ).toMatchObject({
      T3CODE_PORT: String(root.start),
      T3CODE_PORT_END: String(root.end),
    });
  });

  it("lets extraEnv pin a port", () => {
    expect(
      projectScriptRuntimeEnv({ project: { cwd: "/repo" }, extraEnv: { T3CODE_PORT: "3000" } })
        .T3CODE_PORT,
    ).toBe("3000");
  });
});
