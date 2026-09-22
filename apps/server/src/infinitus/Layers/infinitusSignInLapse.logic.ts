import type { ProviderRuntimeEvent } from "@infinitus/contracts";
import type { InfinitusManifestCommand } from "@infinitus/contracts/infinitus";

/**
 * Lapsed AWS / gcloud sign-in detection (#1076), the pure half: the Mac's
 * transcript-scan signature tables (`AwsLogin.swift`, `GcloudLogin.swift`,
 * ported verbatim) applied to a tool result the Claude driver just relayed.
 * A hit names the profile the failed command addressed — the error text's
 * own `--profile` when it prints one, else the Bash command's `--profile` /
 * `AWS_PROFILE` (`--account` / `CLOUDSDK_CORE_ACCOUNT` for gcloud), else
 * `default`; gcloud's Application Default Credentials are the
 * `application-default` account, whatever the command named.
 */

export type SignInProvider = "aws" | "gcloud";

export interface SignInLapse {
  readonly provider: SignInProvider;
  readonly profile: string;
}

/** The work-log row a hit leaves on the thread. */
export const SIGN_IN_MARKER_KIND = "infinitus.signin.needed";

/** One row and one login per thread per profile inside this window. */
export const SIGN_IN_DEBOUNCE_MS = 60 * 60 * 1000;

/** Only the tail is scanned: the CLIs print the failure last, and a tool
    result can run to hundreds of kilobytes. */
const SCAN_TAIL_BYTES = 16 * 1024;

interface Signature {
  /** Any of these anywhere in the (lowercased) text means "lapsed"… */
  readonly markers: ReadonlyArray<string>;
  /** …provided one of these OPENS a line: the CLIs print at column 0 and
      the broker's advisory is indented by exactly two spaces, while the
      same words quoted from a source file, a grep hit or a line-numbered
      Read don't — the sessions working on this feature lit up as needing
      a login (Mac, 2026-09-03). */
  readonly lineStarts: ReadonlyArray<string>;
}

const AWS: Signature = {
  markers: [
    "please reauthenticate using 'aws login'",
    "error when retrieving token from sso",
    "the sso session associated with this profile has expired",
    "the sso session has expired",
    "fix: aws login",
    "run: aws login",
    "please run: aws login",
    "pending authorization to retrieve an sso token has expired",
    "the security token included in the request is expired",
    "waiting for the refresh lock held by pid",
    "aws auth failed — run 'aws login",
  ],
  lineStarts: [
    "aws: [error]",
    "[aws-cred-broker]",
    "error when retrieving token from sso",
    "the sso session",
    "  fix: aws login",
    "[codebuild] aws auth failed",
  ],
};

const GCLOUD: Signature = {
  markers: [
    "$ gcloud auth login",
    "gcloud auth application-default login",
    "there was a problem refreshing your current auth tokens",
    "reauthentication required",
    "reauthentication is needed",
    "reauthentication failed",
    "you do not currently have an active account selected",
    "your default credentials were not found",
    "could not automatically determine credentials",
  ],
  lineStarts: [
    "error: (gcloud.",
    "google.auth.exceptions.",
    "reauthentication required",
    "reauthentication is needed",
    "  $ gcloud auth login",
    "  $ gcloud auth application-default login",
  ],
};

/** gcloud needs that are about Application Default Credentials. */
const GCLOUD_ADC_MARKERS = [
  "application-default login",
  "your default credentials were not found",
  "could not automatically determine credentials",
];

const AWS_TEXT_PROFILE = /aws (?:sso )?login(?: --remote)?(?: --profile[ =]([A-Za-z0-9._-]+))/;
const AWS_COMMAND_PROFILE = /(?:--profile[ =]|AWS_PROFILE=)["']?([A-Za-z0-9._-]+)/;
const GCLOUD_COMMAND_ACCOUNT = /(?:--account[ =]|CLOUDSDK_CORE_ACCOUNT=)["']?([A-Za-z0-9._%+@-]+)/;

const matches = (lower: string, signature: Signature): boolean =>
  signature.markers.some((marker) => lower.includes(marker)) &&
  lower.split("\n").some((line) => signature.lineStarts.some((start) => line.startsWith(start)));

/**
 * The sign-in a tool result says has lapsed, or null. `command` is the Bash
 * command that produced it, when known.
 */
export function signInLapse(text: string, command?: string): SignInLapse | null {
  const tail = text.length > SCAN_TAIL_BYTES ? text.slice(-SCAN_TAIL_BYTES) : text;
  const lower = tail.toLowerCase();
  if (matches(lower, AWS)) {
    const named = AWS_TEXT_PROFILE.exec(tail)?.[1] ?? null;
    const profile =
      named ?? (command === undefined ? null : AWS_COMMAND_PROFILE.exec(command)?.[1]);
    return { provider: "aws", profile: profile ?? "default" };
  }
  if (matches(lower, GCLOUD)) {
    if (GCLOUD_ADC_MARKERS.some((marker) => lower.includes(marker))) {
      return { provider: "gcloud", profile: "application-default" };
    }
    const account = command === undefined ? null : GCLOUD_COMMAND_ACCOUNT.exec(command)?.[1];
    return { provider: "gcloud", profile: account ?? "default" };
  }
  return null;
}

/** Env assignments a shell allows ahead of the command word. */
const ENV_PREFIX = /^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*/;
const AWS_LOGIN_RUN = /^aws\s+(?:sso\s+)?login\b/;
const GCLOUD_LOGIN_RUN = /^gcloud\s+auth\s+(application-default\s+)?login\b/;
const GCLOUD_LOGIN_ACCOUNT = /\blogin\s+([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+)/;
/** banyan's `bun scripts/agent-login.ts <aws|gcp>` wraps the same two CLIs
    (its same-device mode is plain `aws login` / `gcloud auth login`), and
    a login it opens is otherwise invisible (2026-09-22: a browser tab and
    no card). Its AWS default is the `banyan` profile. */
const AGENT_LOGIN_RUN = /\bagent-login\.ts\s+(aws|gcp)\b/;

/**
 * The sign-in a Bash command is itself running, or null: an agent that types
 * `aws login` blocks on a browser nobody is shown, and prints no lapse
 * signature at all. Only a login that OPENS a command counts — quoted spans
 * are flattened to one word and the rest split on the shell's separators —
 * so a grep for the words, an echo of them or a commit message stays quiet
 * (same incident as `lineStarts`). A heredoc body line that opens with the
 * command still matches; accepted.
 */
export function signInRun(command: string): SignInLapse | null {
  // A quoted span keeps its name characters (a quoted profile still reads)
  // and loses the rest, spaces and separators included, so it is one word.
  const bare = command
    .replace(/\\\n/g, " ")
    .replace(/"((?:[^"\\]|\\.)*)"|'([^']*)'/g, (_, double?: string, single?: string) =>
      (double ?? single ?? "").replace(/[^A-Za-z0-9._%+@-]/g, "_"),
    );
  for (const part of bare.split(/&&|\|\||[;|\n(]/)) {
    const segment = part.trim();
    const run = segment.replace(ENV_PREFIX, "");
    // Reading the manual opens no browser.
    if (/\s(?:--help|-h|help)(?:\s|$)/.test(run)) continue;
    if (AWS_LOGIN_RUN.test(run)) {
      return { provider: "aws", profile: AWS_COMMAND_PROFILE.exec(segment)?.[1] ?? "default" };
    }
    const wrapped = AGENT_LOGIN_RUN.exec(run);
    if (wrapped !== null) {
      return wrapped[1] === "aws"
        ? { provider: "aws", profile: AWS_COMMAND_PROFILE.exec(segment)?.[1] ?? "banyan" }
        : { provider: "gcloud", profile: "default" };
    }
    const gcloud = GCLOUD_LOGIN_RUN.exec(run);
    if (gcloud === null) continue;
    if (gcloud[1] !== undefined) return { provider: "gcloud", profile: "application-default" };
    const account =
      GCLOUD_COMMAND_ACCOUNT.exec(segment)?.[1] ?? GCLOUD_LOGIN_ACCOUNT.exec(run)?.[1];
    return { provider: "gcloud", profile: account ?? "default" };
  }
  return null;
}

/** A tool result block's text: a string, or its text parts joined. */
function toolResultText(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(toolResultText).join("");
  if (value === null || typeof value !== "object") return "";
  const record = value as { readonly text?: unknown; readonly content?: unknown };
  return typeof record.text === "string" ? record.text : toolResultText(record.content);
}

/**
 * The lapse an `item.updated` event carries, or null: the Claude driver
 * relays each tool result as one, with the raw `tool_result` block under
 * `payload.data.result` and the tool's input beside it, and a tool's start
 * as one with the input alone — read for a login the command runs itself
 * (`signInRun`). Every other event is null.
 */
export function signInLapseFromEvent(event: ProviderRuntimeEvent): SignInLapse | null {
  if (event.type !== "item.updated") return null;
  const data = event.payload.data;
  if (data === null || typeof data !== "object") return null;
  const { result, input } = data as { readonly result?: unknown; readonly input?: unknown };
  const command =
    input !== null && typeof input === "object" && "command" in input
      ? (input as { readonly command?: unknown }).command
      : undefined;
  if (result === undefined) return typeof command === "string" ? signInRun(command) : null;
  if (result === null || typeof result !== "object") return null;
  const block = result as { readonly type?: unknown; readonly content?: unknown };
  if (block.type !== "tool_result") return null;
  const text = toolResultText(block.content);
  if (text.length === 0) return null;
  return signInLapse(text, typeof command === "string" ? command : undefined);
}

export function signInVerb(provider: SignInProvider): "aws-login" | "gcloud-login" {
  return provider === "aws" ? "aws-login" : "gcloud-login";
}

export function manifestHasVerb(
  commands: ReadonlyArray<InfinitusManifestCommand>,
  verb: string,
): boolean {
  return commands.some((command) => command.name === verb);
}

/** Whether the Mac already has a login running for this credential, read off
    the snapshot's `aws-logins` reply: a phase past `done`/`failed` is over,
    anything else is still waiting on a person and must not be restarted. */
export function hasLoginInFlight(
  logins: ReadonlyArray<{
    readonly profile: string;
    readonly provider?: string | null;
    readonly state?: { readonly phase: string } | null;
  }>,
  lapse: SignInLapse,
): boolean {
  return logins.some((login) => {
    const provider = login.provider === "gcloud" ? "gcloud" : "aws";
    if (provider !== lapse.provider || login.profile !== lapse.profile) return false;
    const phase = login.state?.phase;
    return phase !== undefined && phase !== "done" && phase !== "failed";
  });
}

/** "AWS sign-in needed on papaya" / "gcloud sign-in needed on application-default". */
export function signInMarkerSummary(lapse: SignInLapse): string {
  return `${lapse.provider === "aws" ? "AWS" : "gcloud"} sign-in needed on ${lapse.profile}`;
}
