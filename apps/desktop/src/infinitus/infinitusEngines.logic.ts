/**
 * The pure half of the shell's engine supervision (#1177 follow-up): where an
 * engine's binary lives, what command runs it, and how fast to try again when
 * it dies.
 *
 * The desktop runs the engines rather than the menu-bar app, the placement the
 * user ruled for #1213 and again for this: a shell that cannot start an engine
 * is helpless on a machine where the menu-bar app is not running, which is
 * exactly the machine that needs it. `InfinitusOAuthSignIn.ts` records the same
 * ruling.
 *
 * Detection decides the MODE, never the user. An engine already owned by a
 * service manager is left alone — a second supervisor on top of launchd only
 * fights it — and one we can run ourselves becomes a child of this process. A
 * typed command is always ours to run, which is how a takeover is expressed.
 */

import type { InfinitusEngineKey, InfinitusEngineMode } from "@infinitus/contracts/infinitus";
import { compareSemverVersions } from "@infinitus/shared/semver";

/** Where to look, in order, for an engine binary. The desktop has no user PATH
    (#1078: a login-item-launched app inherits launchd's), so every candidate is
    absolute — the same rule `resolveSwapdBinary` follows. */
export interface EngineDetectionInput {
  readonly homeDirectory: string | undefined;
  /** A runnable program. */
  readonly isExecutable: (path: string) => boolean;
  /** Any file. A launch agent plist is not executable, and it is the thing
      that says launchd already owns an engine. */
  readonly fileExists: (path: string) => boolean;
  readonly listDirectory: (path: string) => ReadonlyArray<string>;
}

export interface EngineDefinition {
  readonly key: InfinitusEngineKey;
  readonly label: string;
  /** The executable's name in the directories searched. */
  readonly binary: string;
  /**
   * Arguments the child is started with. 9Router needs `-t` (tray): without it
   * the CLI is a terminal menu, and a child has no terminal — the menu reads
   * that as "Exit" and takes the server down seconds after it came up. Tray
   * mode stays in the foreground and exits cleanly on SIGTERM, which is all a
   * supervisor needs.
   */
  readonly args: ReadonlyArray<string>;
  /** The Homebrew formula whose launchd job means this engine is already
      supervised, when it has one. */
  readonly brewFormula: string | null;
}

export const ENGINE_DEFINITIONS: ReadonlyArray<EngineDefinition> = [
  {
    key: "cliproxy",
    label: "CLIProxyAPI",
    binary: "cliproxyapi",
    args: [],
    brewFormula: "cliproxyapi",
  },
  {
    key: "9router",
    label: "9Router",
    binary: "9router",
    args: ["-t", "-n", "-H", "127.0.0.1"],
    brewFormula: null,
  },
];

const NVM_VERSIONS_DIR = ".nvm/versions/node";
const BREW_BINARIES = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"];

/**
 * The directories an engine binary may live in, newest nvm version first. Kept
 * beside `knownPosixCliDirCandidates` in `../shell/InfinitusPosixCliDirs.ts`
 * rather than shared with it: that list exists to repair the backend's PATH and
 * is ordered for finding `claude`, and tying an engine's lookup to it would
 * make either list unsafe to reorder for its own reason.
 */
export const engineBinaryDirs = (
  input: Pick<EngineDetectionInput, "homeDirectory" | "listDirectory">,
): ReadonlyArray<string> => {
  const home = input.homeDirectory;
  if (home === undefined) return ["/opt/homebrew/bin", "/usr/local/bin"];
  const nvmVersions = [...input.listDirectory(`${home}/${NVM_VERSIONS_DIR}`)]
    .sort((left, right) => compareSemverVersions(right, left))
    .map((version) => `${home}/${NVM_VERSIONS_DIR}/${version}/bin`);
  return [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    `${home}/.local/bin`,
    ...nvmVersions,
    `${home}/.volta/bin`,
    `${home}/.bun/bin`,
  ];
};

/** Homebrew writes one launch agent per started service; its presence is the
    cheapest honest way to know launchd already owns the engine — no subprocess,
    no `brew services list` on the main process. */
const brewServicePlist = (homeDirectory: string | undefined, formula: string): string | null =>
  homeDirectory === undefined
    ? null
    : `${homeDirectory}/Library/LaunchAgents/homebrew.mxcl.${formula}.plist`;

export interface EngineDetection {
  readonly mode: InfinitusEngineMode;
  /** The command detection would run, or the service command to show. Null when
      the engine is not on this machine. */
  readonly command: string | null;
}

/**
 * What running this engine would mean on this machine. A service manager that
 * already owns it wins over a binary we could spawn: the engine is up, and
 * taking it over would need it stopped there first.
 */
export const detectEngine = (
  definition: EngineDefinition,
  input: EngineDetectionInput,
): EngineDetection => {
  const plist =
    definition.brewFormula === null
      ? null
      : brewServicePlist(input.homeDirectory, definition.brewFormula);
  if (plist !== null && input.fileExists(plist)) {
    const brew = BREW_BINARIES.find((path) => input.isExecutable(path)) ?? "brew";
    return { mode: "service", command: `${brew} services start ${definition.brewFormula}` };
  }
  const found = engineBinaryDirs(input)
    .map((dir) => `${dir}/${definition.binary}`)
    .find((path) => input.isExecutable(path));
  if (found === undefined) return { mode: "unknown", command: null };
  return { mode: "child", command: [quoteArgument(found), ...definition.args].join(" ") };
};

/** A path with a space in it still has to survive the round trip through the
    editable field, so detection quotes what it writes there. */
const quoteArgument = (value: string): string =>
  /[\s"']/.test(value) ? `"${value.replaceAll('"', '\\"')}"` : value;

export interface EngineResolution {
  readonly mode: InfinitusEngineMode;
  readonly command: string | null;
  readonly detectedCommand: string | null;
}

/**
 * The command in force for an engine. A typed one replaces detection's and
 * makes the engine ours to run — that is how taking over a service-managed
 * engine is expressed, once it has been stopped there.
 */
export const resolveEngine = (
  definition: EngineDefinition,
  input: EngineDetectionInput,
  typedCommand: string | null,
): EngineResolution => {
  const detected = detectEngine(definition, input);
  const typed = typedCommand?.trim() ?? "";
  if (typed.length > 0) {
    return { mode: "child", command: typed, detectedCommand: detected.command };
  }
  return { mode: detected.mode, command: detected.command, detectedCommand: detected.command };
};

export type CommandLine =
  | { readonly ok: true; readonly binary: string; readonly args: ReadonlyArray<string> }
  | { readonly ok: false; readonly error: string };

const ABSOLUTE_PATH_ERROR =
  "Start the command with the program's full path — this app does not inherit your shell's PATH.";
const EMPTY_COMMAND_ERROR = "No command to run.";
const UNBALANCED_QUOTE_ERROR = "The command has an unclosed quote.";

/**
 * Split a command into a program and its arguments. No shell runs it — there is
 * no pipe, redirect or variable to honour, and spawning through one would hand
 * a settings field to `sh`. Quotes are understood only so a path with a space
 * in it can be written down.
 */
export const parseCommandLine = (command: string): CommandLine => {
  const tokens: Array<string> = [];
  let current = "";
  let quote: '"' | "'" | null = null;
  let started = false;
  for (let index = 0; index < command.length; index += 1) {
    const char = command[index]!;
    if (quote !== null) {
      if (char === "\\" && quote === '"' && command[index + 1] === '"') {
        current += '"';
        index += 1;
        continue;
      }
      if (char === quote) {
        quote = null;
        continue;
      }
      current += char;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      started = true;
      continue;
    }
    if (char === " " || char === "\t") {
      if (started) tokens.push(current);
      current = "";
      started = false;
      continue;
    }
    current += char;
    started = true;
  }
  if (quote !== null) return { ok: false, error: UNBALANCED_QUOTE_ERROR };
  if (started) tokens.push(current);
  const [binary, ...args] = tokens;
  if (binary === undefined) return { ok: false, error: EMPTY_COMMAND_ERROR };
  if (!binary.startsWith("/")) return { ok: false, error: ABSOLUTE_PATH_ERROR };
  return { ok: true, binary, args };
};

/** The delays a repeatedly dying engine is retried after, the Mac
    supervisor's own (`EventFeed.swift` `SupervisorBackoff`). */
const ENGINE_BACKOFF_CAP_SECONDS = 60;
/** A run this long counts as healthy, so the next death starts over at 1 s. */
const ENGINE_BACKOFF_RESET_SECONDS = 300;

export const engineBackoffSeconds = (attempt: number): number =>
  Math.min(2 ** Math.max(attempt, 0), ENGINE_BACKOFF_CAP_SECONDS);

/**
 * The attempt THIS death is charged, which is the Mac's `noteExit` before its
 * `nextDelay`: a run that lasted starts over, so the first retry after a
 * healthy stretch waits a second rather than a minute. The caller stores this
 * plus one.
 */
export const engineBackoffAttemptFor = (attempt: number, ranForSeconds: number): number =>
  ranForSeconds >= ENGINE_BACKOFF_RESET_SECONDS ? 0 : attempt;

/** How much of the engine's own stderr is worth putting in a settings row. */
const MAX_EXIT_DETAIL_CHARS = 200;

/**
 * What an exit means in the card's words. A signal is how a stop reads, so only
 * a status is worth repeating back; whatever the engine printed before it went
 * is the only clue about why, so its last line comes along.
 */
export const engineExitMessage = (
  code: number | null,
  signal: string | null,
  detail?: string,
): string => {
  const base =
    signal !== null
      ? `The engine stopped (${signal}).`
      : `The engine exited with code ${code ?? "unknown"}.`;
  const said = detail?.trim().split("\n").at(-1)?.trim() ?? "";
  if (said.length === 0) return base;
  const cut =
    said.length > MAX_EXIT_DETAIL_CHARS ? `${said.slice(0, MAX_EXIT_DETAIL_CHARS)}…` : said;
  return `${base} ${cut}`;
};
