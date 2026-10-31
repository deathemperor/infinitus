import type { VcsRemoveWorktreeResult } from "@infinitus/contracts";
import { normalizeProjectPathForComparison } from "@infinitus/shared/path";

import type { ThreadShell } from "./types";

export function getOrphanedWorktreePathForThread(
  threads: ReadonlyArray<Pick<ThreadShell, "id" | "worktreePath">>,
  threadId: ThreadShell["id"],
): string | null {
  const targetThread = threads.find((thread) => thread.id === threadId);
  if (!targetThread) {
    return null;
  }

  const targetWorktreePath = targetThread.worktreePath?.trim();
  if (!targetWorktreePath) {
    return null;
  }

  // Threads can store one worktree as `/repo/wt` and `/repo/wt/`, and
  // confirming deletion force-removes the checkout for every thread on it.
  const targetKey = normalizeProjectPathForComparison(targetWorktreePath);
  const isShared = threads.some(
    (thread) =>
      thread.id !== threadId &&
      thread.worktreePath !== null &&
      normalizeProjectPathForComparison(thread.worktreePath) === targetKey,
  );

  return isShared ? null : targetWorktreePath;
}

export function formatWorktreePathForDisplay(worktreePath: string): string {
  const trimmed = worktreePath.trim();
  if (!trimmed) {
    return worktreePath;
  }

  const normalized = trimmed.replace(/\\/g, "/").replace(/\/+$/, "");
  const parts = normalized.split("/");
  const lastPart = parts[parts.length - 1]?.trim() ?? "";
  return lastPart.length > 0 ? lastPart : trimmed;
}

/** The second question after "delete the worktree too?" (#270 A). Off by
    default like Conductor's delete-branch-on-archive; the server keeps a
    branch it had to commit work to, whatever the answer. */
export function branchDeletionPrompt(branch: string): string {
  return [
    `Also delete branch "${branch}"?`,
    "",
    "Uncommitted work is committed to the branch first, and a branch that had to save work is kept.",
  ].join("\n");
}

/** The toast for a removal that committed work; null when the tree was clean. */
export function describeSavedWorktreeWork(
  result: VcsRemoveWorktreeResult,
): { readonly title: string; readonly description: string } | null {
  if (result.savedWorkCommit === null) return null;
  const where = result.branch === null ? "the worktree's branch" : `branch "${result.branch}"`;
  return {
    title: "Uncommitted work saved",
    description: `Committed to ${where} as ${result.savedWorkCommit.slice(0, 7)}; the branch was kept.`,
  };
}
