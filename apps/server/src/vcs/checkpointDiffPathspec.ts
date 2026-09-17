import * as Effect from "effect/Effect";

import { splitNullSeparatedGitStdoutPaths } from "./GitVcsDriverCore.ts";
import type * as VcsDriver from "./VcsDriver.ts";

/**
 * Restricts a checkpoint-to-checkpoint diff to the paths the thread still
 * changes against its base branch (#1403).
 *
 * A rebase inside a turn puts every commit that landed on the base branch
 * into that turn's checkpoint, so the turn's diff and files list attribute
 * them to the thread. The pathspec keeps a path only when it changed during
 * the turn and its content in the `to` checkpoint still differs from the
 * base tip, re-resolved on every call. A file the agent and the base both
 * touched keeps its whole from→to hunks: a pathspec cannot split hunks.
 *
 * Returns `null` when no base branch resolves (detached HEAD, the thread
 * works on the base branch itself, or a listing fails) or the paths would
 * not fit the command line (git diff takes no pathspec file), which leaves
 * the diff unrestricted.
 */
export const resolveCheckpointDiffPathspec = Effect.fn("resolveCheckpointDiffPathspec")(function* (
  execute: VcsDriver.VcsDriver["Service"]["execute"],
  input: {
    readonly cwd: string;
    readonly fromRevision: string;
    readonly toRevision: string;
  },
) {
  const baseRef = yield* resolveCheckpointDiffBase(execute, input.cwd);
  if (!baseRef) return null;

  const listChanged = (from: string, to: string) =>
    execute({
      operation: "GitVcsDriver.checkpoints.diffCheckpoints.pathspec",
      cwd: input.cwd,
      args: ["diff", "--name-only", "-z", "--no-renames", `${from}^{commit}`, `${to}^{commit}`],
      outputMode: "error",
      maxOutputBytes: 4_000_000,
    }).pipe(
      Effect.map(splitNullSeparatedGitStdoutPaths),
      Effect.orElseSucceed(() => null),
    );

  const changedInTurn = yield* listChanged(input.fromRevision, input.toRevision);
  if (changedInTurn === null) return null;
  const changedAgainstBase = yield* listChanged(baseRef, input.toRevision);
  if (changedAgainstBase === null) return null;

  const stillDiffersFromBase = new Set(changedAgainstBase);
  const pathspec = changedInTurn.filter((path) => stillDiffersFromBase.has(path));
  const bytes = pathspec.reduce((total, path) => total + Buffer.byteLength(path) + 1, 0);
  return bytes > PATHSPEC_ARGV_BUDGET_BYTES ? null : pathspec;
});

/** Well under every platform's argument limit (macOS 1 MB, Linux 2 MB). */
const PATHSPEC_ARGV_BUDGET_BYTES = 400_000;

const DEFAULT_BASE_BRANCH_CANDIDATES = ["main", "master"] as const;

/**
 * The base the branch scope diffs against, as a full ref: the branch's
 * `gh-merge-base`, then origin's default branch, then `main` / `master`,
 * each preferred as `origin/<name>` over the local branch. Mirrors
 * `resolveBaseBranchForNoUpstream` in GitVcsDriverCore without its
 * layer requirements.
 */
const resolveCheckpointDiffBase = Effect.fn("resolveCheckpointDiffBase")(function* (
  execute: VcsDriver.VcsDriver["Service"]["execute"],
  cwd: string,
) {
  const readStdout = (args: ReadonlyArray<string>) =>
    execute({
      operation: "GitVcsDriver.checkpoints.diffCheckpoints.base",
      cwd,
      args,
      allowNonZeroExit: true,
      maxOutputBytes: 4_096,
    }).pipe(
      Effect.map((result) => (result.exitCode === 0 ? result.stdout.trim() : "")),
      Effect.orElseSucceed(() => ""),
    );

  const branch = yield* readStdout(["symbolic-ref", "--short", "--quiet", "HEAD"]);
  if (branch.length === 0) return null;

  const configured = yield* readStdout(["config", "--get", `branch.${branch}.gh-merge-base`]);
  const originDefault = yield* readStdout([
    "symbolic-ref",
    "--short",
    "--quiet",
    "refs/remotes/origin/HEAD",
  ]);
  for (const candidate of [configured, originDefault, ...DEFAULT_BASE_BRANCH_CANDIDATES]) {
    const name = candidate.startsWith("origin/") ? candidate.slice("origin/".length) : candidate;
    if (name.length === 0 || name === branch) continue;
    for (const ref of [`refs/remotes/origin/${name}`, `refs/heads/${name}`]) {
      const commit = yield* readStdout(["rev-parse", "--verify", "--quiet", `${ref}^{commit}`]);
      if (commit.length > 0) return ref;
    }
  }
  return null;
});
