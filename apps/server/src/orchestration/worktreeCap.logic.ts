/**
 * Worktree limit (#269 H; Cursor's max worktrees). A bootstrap that would
 * create a worktree is refused once `worktreeMaxCount` live threads already
 * hold one — before the thread is created, so the send costs nothing.
 * Archived threads keep their worktree until they are deleted, so the
 * refusal names the oldest of those: deleting one frees a worktree.
 */

export interface WorktreeHolders {
  /** Live (non-deleted) threads with a worktree, archived or not. */
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

/** The refusal for a new worktree, or null when one may be created. */
export function worktreeCapRefusal(holders: WorktreeHolders, max: number): string | null {
  if (max <= 0 || holders.count < max) return null;
  const head = `Worktree limit reached: ${holders.count} of ${max} threads hold a worktree.`;
  const fix =
    holders.oldestArchived.length === 0
      ? "Delete a thread you no longer need to free its worktree, or raise the limit in Settings → General."
      : `Delete an archived thread to free its worktree (oldest: ${holders.oldestArchived
          .map((thread) => `“${boundedTitle(thread.title)}”`)
          .join(", ")}), or raise the limit in Settings → General.`;
  return `${head} ${fix}`;
}
