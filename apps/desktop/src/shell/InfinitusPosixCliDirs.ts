import { compareSemverVersions } from "@infinitus/shared/semver";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";

/**
 * Known CLI install directories for the desktop's PATH on macOS (#1078), the
 * POSIX sibling of upstream's `knownWindowsCliDirs`. The login-shell probe in
 * DesktopShellEnvironment stays the first choice: these only join PATH when
 * that probe answered nothing (a `.zshrc` slower than its 5 s timeout leaves
 * the backend on launchd's bare PATH) or answered a PATH with no `claude` on
 * it, and then after the probe's own entries, so a user's PATH still wins.
 */

/** Why the known directories were consulted. */
export type PosixCliDirFallbackReason = "no-shell-path" | "no-claude-on-shell-path";

export interface PosixCliDirFallback {
  readonly reason: PosixCliDirFallbackReason;
  /** The known directories that exist, in precedence order. */
  readonly dirs: ReadonlyArray<string>;
  /** The first known directory holding a `claude` executable, if any. */
  readonly claudeDir: string | null;
}

export interface PosixCliDirFallbackInput {
  readonly homeDirectory: string | undefined;
  /** PATH from the login-shell probe (or launchctl), if it answered. */
  readonly shellPath: Option.Option<string>;
  readonly exists: (path: string) => boolean;
  readonly listDirectory: (path: string) => ReadonlyArray<string>;
}

const CLAUDE_EXECUTABLE = "claude";
const NVM_VERSIONS_DIR = ".nvm/versions/node";

const hasClaude = (dir: string, exists: (path: string) => boolean) =>
  exists(`${dir}/${CLAUDE_EXECUTABLE}`);

/** nvm's per-version bins, newest version first. */
const nvmNodeBinDirs = (
  homeDirectory: string,
  listDirectory: (path: string) => ReadonlyArray<string>,
): ReadonlyArray<string> => {
  const versionsDir = `${homeDirectory}/${NVM_VERSIONS_DIR}`;
  return [...listDirectory(versionsDir)]
    .sort((left, right) => compareSemverVersions(right, left))
    .map((version) => `${versionsDir}/${version}/bin`);
};

/** The directories to try, before the existence filter. */
export const knownPosixCliDirCandidates = (
  homeDirectory: string | undefined,
  listDirectory: (path: string) => ReadonlyArray<string>,
): ReadonlyArray<string> => {
  const home = homeDirectory === undefined ? [] : [homeDirectory];
  return [
    ...home.map((h) => `${h}/.claude/local`),
    ...home.map((h) => `${h}/.local/bin`),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    ...home.flatMap((h) => nvmNodeBinDirs(h, listDirectory)),
    ...home.map((h) => `${h}/.volta/bin`),
    ...home.map((h) => `${h}/.bun/bin`),
  ];
};

/**
 * Pure: decides whether the known directories are needed and which of them
 * exist. `null` when the shell's PATH already reaches `claude`.
 */
export const resolvePosixCliDirFallback = (
  input: PosixCliDirFallbackInput,
): PosixCliDirFallback | null => {
  const shellDirs = Option.match(input.shellPath, {
    onNone: () => null,
    onSome: (value) => value.split(":").filter((entry) => entry.length > 0),
  });
  if (shellDirs !== null && shellDirs.some((dir) => hasClaude(dir, input.exists))) {
    return null;
  }
  const dirs = knownPosixCliDirCandidates(input.homeDirectory, input.listDirectory).filter((dir) =>
    input.exists(dir),
  );
  return {
    reason: shellDirs === null ? "no-shell-path" : "no-claude-on-shell-path",
    dirs,
    claudeDir: dirs.find((dir) => hasClaude(dir, input.exists)) ?? null,
  };
};

/**
 * The known directories as one PATH value for DesktopShellEnvironment's merge,
 * `None` when the shell's PATH already reaches `claude` or nothing exists.
 * Every filesystem probe runs up front so the resolver stays pure; logs which
 * directories joined and which one holds `claude`.
 */
export const knownPosixCliPath = Effect.fn("desktop.shellEnvironment.knownPosixCliPath")(
  function* (input: {
    readonly homeDirectory: string | undefined;
    readonly shellPath: Option.Option<string>;
  }): Effect.fn.Return<Option.Option<string>, never, FileSystem.FileSystem> {
    const fileSystem = yield* FileSystem.FileSystem;
    const nvmVersions =
      input.homeDirectory === undefined
        ? []
        : yield* fileSystem
            .readDirectory(`${input.homeDirectory}/${NVM_VERSIONS_DIR}`)
            .pipe(Effect.orElseSucceed((): ReadonlyArray<string> => []));
    const listDirectory = () => nvmVersions;
    const candidates = knownPosixCliDirCandidates(input.homeDirectory, listDirectory);
    const shellDirs = Option.getOrElse(input.shellPath, () => "").split(":");
    const probes = [
      ...candidates,
      ...candidates.map((dir) => `${dir}/${CLAUDE_EXECUTABLE}`),
      ...shellDirs.filter((dir) => dir.length > 0).map((dir) => `${dir}/${CLAUDE_EXECUTABLE}`),
    ];
    const existing = new Set(
      yield* Effect.filter(probes, (path) =>
        fileSystem.exists(path).pipe(Effect.orElseSucceed(() => false)),
      ),
    );
    const fallback = resolvePosixCliDirFallback({
      ...input,
      exists: (path) => existing.has(path),
      listDirectory,
    });
    if (fallback === null || fallback.dirs.length === 0) {
      return Option.none();
    }
    yield* Effect.logInfo("known CLI directories added to PATH").pipe(
      Effect.annotateLogs({
        component: "desktop-shell-environment",
        reason: fallback.reason,
        dirs: fallback.dirs,
        claudeDir: fallback.claudeDir,
      }),
    );
    return Option.some(fallback.dirs.join(":"));
  },
);
