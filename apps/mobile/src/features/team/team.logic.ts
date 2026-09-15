import type {
  InfinitusCommandInput,
  InfinitusManifestCommand,
  InfinitusSecretInput,
} from "@t3tools/contracts/infinitus";
import { InfinitusTeamSnapshot } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

import { commandFailureMessage } from "../accounts/accountsRoute.logic";
import { UNIVERSAL_PAIR_HOST } from "../connection/universalPairLink.logic";

/**
 * Settings › Team (#1313), the phone's half of the web pane's
 * `team.logic.ts`: read `team-status`, fetch, approve and decline over
 * `infinitus.command`; join over `infinitus.secret` with the code on stdin.
 * The phone never creates a team, chooses what is shared or leaves (spec
 * §6.3); those stay on the Mac and the desktop.
 */

export type TeamStatus = InfinitusTeamSnapshot;

/** A build that answers `team-status`. */
export function teamStatusSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "team-status");
}

/** `team-join` with the code on stdin, which is what opens `infinitus.secret`. */
export function teamJoinSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "team-join" && command.stdin === "secret");
}

const decodeTeamStatus = Schema.decodeUnknownOption(InfinitusTeamSnapshot);

/**
 * A `team-status` reply: `{ team }` with null when this Mac is in no team
 * (the verb answers `null` then), or null when the shape is not the contract's.
 */
export function parseTeamStatus(result: unknown): { readonly team: TeamStatus | null } | null {
  if (result === null || result === undefined) return { team: null };
  const decoded = decodeTeamStatus(result);
  return Option.isNone(decoded) ? null : { team: decoded.value };
}

export type TeamAction =
  | { readonly type: "status" }
  | { readonly type: "fetch" }
  | { readonly type: "approve"; readonly kid: string }
  | { readonly type: "decline"; readonly kid: string };

/** The `infinitus.command` input for one secret-free action; every one answers `team-status`. */
export function teamCommandInput(action: TeamAction): InfinitusCommandInput {
  switch (action.type) {
    case "status":
      return { command: "team-status", args: [], options: {} };
    case "fetch":
      return { command: "team-fetch", args: [], options: {} };
    case "approve":
      return { command: "team-approve", args: [action.kid], options: {} };
    case "decline":
      return { command: "team-decline", args: [action.kid], options: {} };
  }
}

/** The Mac's roster name for `team-join`, trimmed; null when blank or too long for the secret layer. */
export function teamMemberName(raw: string): string | null {
  const name = raw.trim();
  return name.length === 0 || name.length > 128 ? null : name;
}

/**
 * `team-join` over `infinitus.secret`: the manifest spells its positional
 * `<your name>`, so that is the args key; the code goes on `secret`, never here.
 */
export function teamJoinSecretArgs(name: string): Omit<InfinitusSecretInput, "secret"> {
  return { command: "team-join", args: { "your name": name } };
}

const JOIN_PATH = "/join";

/**
 * The code a team invite link carries (#1313): `https://infinitus.run/join#<code>`,
 * the same host as the pairing link and the same reason (a universal link only
 * fires for a host with an AASA). The fragment is the whole code, never a
 * query string; null for any other URL or an empty fragment.
 */
export function teamJoinLinkCode(raw: string): string | null {
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    return null;
  }
  if (
    url.protocol !== "https:" ||
    url.hostname !== UNIVERSAL_PAIR_HOST ||
    url.pathname.replace(/\/$/, "") !== JOIN_PATH
  ) {
    return null;
  }
  let code: string;
  try {
    code = decodeURIComponent(url.hash.replace(/^#/, "")).trim();
  } catch {
    return null;
  }
  return code.length === 0 ? null : code;
}

/** What the Join form sends: a pasted invite link becomes its code, anything else is the code itself. */
export function teamJoinCode(raw: string): string {
  return teamJoinLinkCode(raw) ?? raw.trim();
}

/** "leader" → "Leader", anything else capitalised the same way. */
export function teamRoleLabel(role: string): string {
  return role.length === 0 ? role : role[0]!.toUpperCase() + role.slice(1);
}

/** "just now", "5 min ago", "3 h ago", "2 d ago" from unix seconds; "never" for none. */
export function relativeUnix(seconds: number | null | undefined, nowMs: number): string {
  if (seconds === null || seconds === undefined) return "never";
  const ago = Math.max(0, Math.floor(nowMs / 1000) - seconds);
  if (ago < 60) return "just now";
  if (ago < 3600) return `${Math.floor(ago / 60)} min ago`;
  if (ago < 86_400) return `${Math.floor(ago / 3600)} h ago`;
  return `${Math.floor(ago / 86_400)} d ago`;
}

/** One line under a member's name: role, "you", threads now, last published, blockers. */
export function teamMemberSummary(member: TeamStatus["members"][number], nowMs: number): string {
  const parts = [teamRoleLabel(member.role)];
  if (member.isMe) parts.push("you");
  const threads = member.threadsNow ?? 0;
  parts.push(
    `${threads} thread${threads === 1 ? "" : "s"} now`,
    `published ${relativeUnix(member.lastPublished, nowMs)}`,
  );
  if ((member.blockers?.length ?? 0) > 0) parts.push(`blocked: ${member.blockers!.join(", ")}`);
  return parts.join(" · ");
}

/** Whether this Mac leads the team, which is what shows Requests and its buttons. */
export function teamLeads(team: TeamStatus): boolean {
  return team.members.some((member) => member.isMe && member.role === "leader");
}

/**
 * What a failed `infinitus.secret` says. The server's refusals never reached
 * the socket and get a plain sentence each; anything else is the socket's own
 * wording through `commandFailureMessage`.
 */
export function secretFailureMessage(cause: Cause.Cause<unknown>): string {
  const error: unknown = Cause.squash(cause);
  if (typeof error === "object" && error !== null && "_tag" in error) {
    const tagged = error as { readonly _tag: unknown; readonly reason?: unknown };
    if (tagged._tag === "InfinitusSecretRefused") {
      switch (tagged.reason) {
        case "no_manifest":
          return "The server has not read the Infinitus command list yet; try again in a moment.";
        case "no_secret":
          return "This Infinitus build does not take the code on its secret channel.";
        case "bad_args":
          return "The server refused the request's arguments.";
        case "too_many_attempts":
          return "Too many attempts; wait a minute and try again.";
      }
    }
  }
  return commandFailureMessage(cause);
}
