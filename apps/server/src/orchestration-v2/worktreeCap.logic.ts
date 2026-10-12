/**
 * Worktree limit (#269 H; Cursor's max worktrees). A launch that would
 * create a worktree is refused once `worktreeMaxCount` worktrees are held by
 * live threads — before the thread is created, so the send costs nothing.
 * Archived threads keep their worktree until they are deleted, so the
 * refusal names the oldest of those: deleting one frees a worktree.
 */

export interface WorktreeHolders {
  /** Distinct worktrees held by live (non-deleted) threads, archived or not. */
  readonly count: number;
  /** The archived holders, oldest archive first, up to a few. */
  readonly oldestArchived: ReadonlyArray<{ readonly title: string; readonly archivedAt: string }>;
}

/** How many archived holders the refusal names. */
export const WORKTREE_CAP_SUGGESTIONS = 3;

/** One line, bounded: the title is the user's. */
function boundedTitle(title: string): string {
  const flat = title.replace(/\s+/g, " ").trim();
  const shown = flat.length === 0 ? "Untitled" : flat;
  return shown.length > 40 ? `${shown.slice(0, 39)}…` : shown;
}

/**
 * The refusal for a new worktree, or null when one may be created. `inFlight`
 * counts the worktrees other launches are creating right now (a multi-model
 * send starts its threads together): they hold one before the projection
 * says so.
 */
export function worktreeCapRefusal(
  holders: WorktreeHolders,
  max: number,
  inFlight = 0,
): string | null {
  const count = holders.count + inFlight;
  if (max <= 0 || count < max) return null;
  const head = `Worktree limit reached: ${count} of ${max} worktrees are in use.`;
  const fix =
    holders.oldestArchived.length === 0
      ? "Delete a thread you no longer need to free its worktree, or raise the Worktree limit in the server's settings."
      : `Delete an archived thread to free its worktree (oldest: ${holders.oldestArchived
          .map((thread) => `“${boundedTitle(thread.title)}”`)
          .join(", ")}), or raise the Worktree limit in the server's settings.`;
  return `${head} ${fix}`;
}

/**
 * The refusal as a launch failure's cause. The launch error that wraps it is
 * generic by design (its other causes are git and storage failures the user
 * should not see); the transports pull this one's message back out with
 * `worktreeCapRefusalMessage`.
 */
export class WorktreeCapRefusalError extends Error {
  readonly _tag = "WorktreeCapRefusalError";
  constructor(message: string) {
    super(message);
    this.name = "WorktreeCapRefusalError";
  }
}

/** The refusal text when `error` is a launch failure caused by the cap, else undefined. */
export function worktreeCapRefusalMessage(error: unknown): string | undefined {
  for (let current: unknown = error, depth = 0; current !== null && depth < 4; depth += 1) {
    if (current instanceof WorktreeCapRefusalError) return current.message;
    if (typeof current !== "object" || !("cause" in current)) return undefined;
    current = current.cause;
  }
  return undefined;
}
