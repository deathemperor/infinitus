/**
 * The fork keeps its state in `~/.infinitus`, never the `~/.t3` an installed T3
 * Code runs against: the schemas drift, and the fork never opens the real app's
 * database. An explicit `T3CODE_HOME` still wins, and a linked worktree still gets
 * its own `.t3` (see devHome.ts).
 */
export const DEFAULT_HOME_DIR_NAME = ".infinitus";
