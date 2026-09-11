import type { OrchestrationThreadShell, ThreadId } from "@t3tools/contracts";

/**
 * Best of N (#269 B): one prompt, two to four Claude models, one worktree
 * each. The send starts one thread per chip from the same draft; the
 * draft's own thread id is the first member, so the route promotes the way
 * a plain send does, and every member carries the same `groupId`. Nothing
 * judges the results: the group card on each member lists the siblings and
 * "Keep this one" archives the rest.
 */

export const BEST_OF_MIN = 2;
export const BEST_OF_MAX = 4;

/** A model chosen in the picker; `label` is the model's display name. */
export interface BestOfChip {
  readonly model: string;
  readonly label: string;
}

export interface BestOfMember {
  readonly threadId: ThreadId;
  readonly groupId: string;
  readonly model: string;
  /** The thread's title: the draft's title with the model, so siblings read apart. */
  readonly title: string;
}

/** The title a member is created with; no `titleSeed` rides the send, so it stays. */
export function bestOfMemberTitle(title: string, label: string): string {
  return `${title} · ${label}`;
}

/**
 * The members a best-of send starts, in chip order. Duplicate models count
 * once; fewer than `BEST_OF_MIN` distinct chips is not a bake-off, so null.
 */
export function planBestOfMembers(input: {
  readonly firstThreadId: ThreadId;
  readonly chips: ReadonlyArray<BestOfChip>;
  readonly title: string;
  readonly groupId: string;
  readonly newThreadId: () => ThreadId;
}): ReadonlyArray<BestOfMember> | null {
  const seen = new Set<string>();
  const chips = input.chips.filter((chip) => {
    if (seen.has(chip.model)) return false;
    seen.add(chip.model);
    return true;
  });
  if (chips.length < BEST_OF_MIN || chips.length > BEST_OF_MAX) return null;
  return chips.map((chip, index) => ({
    threadId: index === 0 ? input.firstThreadId : input.newThreadId(),
    groupId: input.groupId,
    model: chip.model,
    title: bestOfMemberTitle(input.title, chip.label),
  }));
}

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
