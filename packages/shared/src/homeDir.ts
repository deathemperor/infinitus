/**
 * The fork keeps its state in `~/.infinitus`, never in the `~/.t3` that a
 * user's installed T3 Code runs against: the two schemas drift, and the
 * standing rule is that the fork never opens the real app's database. An
 * explicit `T3CODE_HOME` still wins, and a linked worktree still gets its own
 * `.t3` (see devHome.ts) — this is only the default home's name.
 */
export const DEFAULT_HOME_DIR_NAME = ".infinitus";
