import type { ThreadId } from "@t3tools/contracts";

/**
 * Fork (#269 C, #863): a thread with `sideOf` set is a hidden side question
 * of another thread. The web shows it in that thread's drawer; the phone has
 * no drawer, so it stays out of every list and never opens as a page.
 */
export function isSideQuestion(thread: { readonly sideOf?: ThreadId | null }): boolean {
  return thread.sideOf != null;
}

/** The threads that are not side questions; the same array when none are. */
export function withoutSideQuestions<T extends { readonly sideOf?: ThreadId | null }>(
  threads: ReadonlyArray<T>,
): ReadonlyArray<T> {
  return threads.some(isSideQuestion)
    ? threads.filter((thread) => !isSideQuestion(thread))
    : threads;
}

/** Archived snapshots with their side questions dropped; each entry is kept
    as is when it has none. */
export function withoutSideQuestionSnapshots<
  T extends {
    readonly snapshot: { readonly threads: ReadonlyArray<{ readonly sideOf?: ThreadId | null }> };
  },
>(entries: ReadonlyArray<T>): ReadonlyArray<T> {
  return entries.map((entry) => {
    const threads = withoutSideQuestions(entry.snapshot.threads);
    return threads === entry.snapshot.threads
      ? entry
      : { ...entry, snapshot: { ...entry.snapshot, threads } };
  });
}
