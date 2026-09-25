import type {
  InfinitusCommandInput,
  InfinitusManifestCommand,
} from "@infinitus/contracts/infinitus";
import { ThreadId } from "@infinitus/contracts";
import { InfinitusTeamExclusions } from "@infinitus/contracts/infinitus";
import type { TeamCapability, TeamGrantCreate } from "@infinitus/contracts/relayInfinitusTeam";
import { InfinitusTeamError } from "@infinitus/client-runtime/relay/infinitusTeam";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/**
 * Settings › Team on Infinitus Connect (#1592): the pane's pure edges. The
 * team itself lives on the relay (`@infinitus/client-runtime/relay/infinitusTeam`);
 * what stays on the Mac is the private-projects list, read and written over
 * `infinitus.command` (`team-exclusions`, `team-exclude`).
 */

/** A Mac whose manifest answers `team-exclusions` (≥ 0.5.0-alpha.36). */
export function teamExclusionsSupported(
  commands: ReadonlyArray<InfinitusManifestCommand>,
): boolean {
  return commands.some((command) => command.name === "team-exclusions");
}

const decodeExclusions = Schema.decodeUnknownOption(InfinitusTeamExclusions);

/** The `team-exclusions` reply's projects; null when the shape is not the contract's. */
export function parseTeamExclusions(result: unknown): ReadonlyArray<string> | null {
  const decoded = decodeExclusions(result);
  return Option.isNone(decoded) ? null : decoded.value.projects;
}

export const TEAM_EXCLUSIONS_INPUT: InfinitusCommandInput = {
  command: "team-exclusions",
  args: [],
  options: {},
};

export function teamExcludeInput(slug: string, on: boolean): InfinitusCommandInput {
  return { command: "team-exclude", args: [on ? "add" : "remove", slug], options: {} };
}

/** A project is its folder's name or its path: trimmed, no whitespace,
    under 256 characters. */
export function teamExclusionSlug(raw: string): string | null {
  const slug = raw.trim();
  return slug.length === 0 || slug.length > 256 || /\s/.test(slug) ? null : slug;
}

/** A roster name: trimmed, 1..64 characters. */
export function teamMemberName(raw: string): string | null {
  const name = raw.trim();
  return name.length === 0 || name.length > 64 ? null : name;
}

/** The kinds a member publishes, in the Mac's order, and what each carries. */
export const TEAM_KINDS: ReadonlyArray<{
  readonly kind: "now" | "threads" | "transcripts" | "stats" | "fleet";
  readonly label: string;
}> = [
  { kind: "now", label: "Now — what this machine is on, blockers" },
  { kind: "threads", label: "Threads — the index of your threads" },
  { kind: "transcripts", label: "Transcripts — your threads' conversations, redacted" },
  { kind: "stats", label: "Stats — messages, tokens, cost per day" },
  { kind: "fleet", label: "Fleet — every account's headroom" },
];

export const TEAM_SHARE_TARGETS: ReadonlyArray<{
  readonly target: "off" | "leaders" | "team";
  readonly label: string;
}> = [
  { target: "off", label: "Nobody" },
  { target: "leaders", label: "Leaders" },
  { target: "team", label: "Whole team" },
];

/** What a grant may let a teammate do to this machine's threads. */
export const TEAM_CAPABILITIES: ReadonlyArray<{
  readonly capability: TeamCapability;
  readonly label: string;
  readonly asks: boolean;
}> = [
  { capability: "view", label: "View a thread's transcript", asks: false },
  { capability: "send", label: "Send a message to a thread", asks: false },
  { capability: "interrupt", label: "Interrupt a running turn", asks: true },
  { capability: "new", label: "Start a new thread", asks: true },
];

const isCapability = (value: string): value is TeamCapability =>
  TEAM_CAPABILITIES.some((entry) => entry.capability === value);

/** The grant form's draft: who, what, which threads (blank = all), what
    runs without asking; null when nothing is picked. */
export function teamGrantDraft(input: {
  readonly environmentId: TeamGrantCreate["environmentId"];
  readonly audience: string;
  readonly capabilities: ReadonlyArray<string>;
  readonly threads: string;
  readonly preauthorized: ReadonlyArray<string>;
}): TeamGrantCreate | null {
  const capabilities = input.capabilities.filter(isCapability);
  const audience = input.audience.trim();
  if (audience.length === 0 || capabilities.length === 0) return null;
  const threads = input.threads
    .split(",")
    .map((id) => id.trim())
    .filter((id) => id.length > 0);
  const preauthorized = input.preauthorized
    .filter(isCapability)
    .filter((capability) => capabilities.includes(capability));
  return {
    environmentId: input.environmentId,
    audience: audience === "leaders" || audience === "team" ? audience : [audience],
    threads: threads.length === 0 ? "all" : threads.map((id) => ThreadId.make(id)),
    capabilities,
    ...(preauthorized.length === 0 ? {} : { preauthorized }),
  };
}

/** What the pane shows for a failed call: the relay's sentence verbatim, a
    trace id on a relay failure, and a plain line for anything else. */
export function teamErrorMessage(error: unknown): string {
  if (error instanceof InfinitusTeamError) {
    return error.kind === "failed" && error.traceId !== null
      ? `${error.message} Trace ID: ${error.traceId}`
      : error.message;
  }
  return error instanceof Error && error.message.length > 0
    ? error.message
    : "Something went wrong.";
}

export function teamRoleLabel(role: "leader" | "member"): string {
  return role === "leader" ? "Leader" : "Member";
}
