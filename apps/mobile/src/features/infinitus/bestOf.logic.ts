import type { OrchestrationThreadShell } from "@t3tools/contracts";

/**
 * Best of N on the phone (#269 B), read-only: the web's `bestOf.logic.ts`
 * sibling and status helpers, kept local so neither app edits the other's
 * file. A member thread carries the group's `groupId`; the card on it lists
 * the group's live siblings. "Keep this one" stays on the desktop — it
 * removes worktrees.
 */

/** The live members of a group, oldest first: archived ones have been "kept" away. */
export function bestOfSiblings<
  T extends Pick<OrchestrationThreadShell, "id" | "groupId" | "archivedAt" | "createdAt">,
>(shells: ReadonlyArray<T>, groupId: string): ReadonlyArray<T> {
  return shells
    .filter((shell) => shell.groupId === groupId && shell.archivedAt === null)
    .sort((left, right) =>
      left.createdAt < right.createdAt
        ? -1
        : left.createdAt > right.createdAt
          ? 1
          : left.id < right.id
            ? -1
            : left.id > right.id
              ? 1
              : 0,
    );
}

/** What `bestOfSiblings` depends on, as one string: the group's members by
    id, kept-away marker and creation time. The card keys its siblings memo on
    it, so the shells array changing identity on every tick of an unrelated
    thread rebuilds nothing (phone audit 2026-09-15). O(N) with no allocation
    per shell that is not a member. */
export function bestOfGroupKey<
  T extends Pick<OrchestrationThreadShell, "id" | "groupId" | "archivedAt" | "createdAt"> & {
    readonly environmentId: string;
  },
>(shells: ReadonlyArray<T>, environmentId: string, groupId: string): string {
  let key = "";
  for (const shell of shells) {
    if (shell.environmentId !== environmentId || shell.groupId !== groupId) continue;
    key += `${shell.id}|${shell.archivedAt ?? ""}|${shell.createdAt};`;
  }
  return key;
}

export type BestOfMemberStatus =
  | "starting"
  | "running"
  | "waiting-approval"
  | "waiting-input"
  | "done"
  | "failed"
  | "stopped";

/** One word per member for the card; approvals and questions outrank "running". */
export function bestOfMemberStatus(
  shell: Pick<
    OrchestrationThreadShell,
    "session" | "latestTurn" | "hasPendingApprovals" | "hasPendingUserInput"
  >,
): BestOfMemberStatus {
  if (shell.hasPendingApprovals) return "waiting-approval";
  if (shell.hasPendingUserInput) return "waiting-input";
  const turn = shell.latestTurn;
  if (turn === null) return shell.session?.status === "starting" ? "starting" : "running";
  switch (turn.state) {
    case "running":
      return "running";
    case "completed":
      return "done";
    case "error":
      return "failed";
    case "interrupted":
      return "stopped";
  }
}

export const BEST_OF_STATUS_LABEL: Record<BestOfMemberStatus, string> = {
  starting: "Starting",
  running: "Running",
  "waiting-approval": "Needs approval",
  "waiting-input": "Needs input",
  done: "Done",
  failed: "Failed",
  stopped: "Stopped",
};

/** The card shows while this thread has at least one live sibling; a group
    down to one member is no bake-off any more. */
export function bestOfCardShown(
  siblings: ReadonlyArray<Pick<OrchestrationThreadShell, "id">>,
  threadId: string,
): boolean {
  return siblings.length > 1 && siblings.some((shell) => shell.id === threadId);
}
