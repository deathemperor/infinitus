import type {
  InfinitusCommandInput,
  InfinitusManifestCommand,
  InfinitusSecretInput,
} from "@t3tools/contracts/infinitus";
import {
  InfinitusTeamCode,
  InfinitusTeamSnapshot,
  type InfinitusTeamGrant,
  type InfinitusTeamMember,
  type InfinitusTeamPending,
} from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

import { infinitusCommandFailure } from "./panel.logic";

/**
 * Settings › Infinitus › Team (#1313): what the page sends over
 * `infinitus.command` (the secret-free `team-*` verbs) and
 * `infinitus.secret` (`team-join` with the code, `team-create` with the
 * remote's token), and how it reads `team-status`. Pure so the page only
 * renders.
 */

/** A build that answers `team-status`. */
export function teamStatusSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "team-status");
}

/** `team-join` with the code on stdin, which is what opens `infinitus.secret`. */
export function teamJoinSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "team-join" && command.stdin === "secret");
}

/** `team-create` with the remote's write token on stdin. */
export function teamCreateSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "team-create" && command.stdin === "secret");
}

export type TeamStatus = InfinitusTeamSnapshot;
export type TeamMember = InfinitusTeamMember;
export type TeamGrant = InfinitusTeamGrant;
export type TeamPending = InfinitusTeamPending;

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

const decodeTeamCode = Schema.decodeUnknownOption(InfinitusTeamCode);

/** The `team-code` reply, null when the shape is not the contract's. */
export function parseTeamCode(result: unknown): InfinitusTeamCode | null {
  return Option.getOrNull(decodeTeamCode(result));
}

/** The kinds a member publishes, in the Mac's order, and what each carries. */
export const TEAM_KINDS: ReadonlyArray<{ readonly kind: string; readonly label: string }> = [
  { kind: "stats", label: "Stats — messages, tokens, cost per day" },
  { kind: "now", label: "Now — what this Mac is on, blockers" },
  { kind: "threads", label: "Threads — the index of your threads" },
  { kind: "transcripts", label: "Transcripts — your threads' conversations, redacted" },
  { kind: "crashes", label: "Crashes — crash reports" },
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

/** Delegated control (spec §8): what a grant may let a teammate do to this Mac's threads. */
export const TEAM_CAPABILITIES: ReadonlyArray<{
  readonly capability: "view" | "send" | "interrupt" | "new";
  readonly label: string;
  readonly asks: boolean;
}> = [
  { capability: "view", label: "View a thread's transcript", asks: false },
  { capability: "send", label: "Send a message to a thread", asks: false },
  { capability: "interrupt", label: "Interrupt a running turn", asks: true },
  { capability: "new", label: "Start a new thread", asks: true },
];

export type TeamAction =
  | { readonly type: "status" }
  | { readonly type: "fetch" }
  | { readonly type: "publish" }
  | { readonly type: "approve"; readonly kid: string }
  | { readonly type: "decline"; readonly kid: string }
  | { readonly type: "remove"; readonly kid: string }
  | { readonly type: "promote"; readonly kid: string }
  | { readonly type: "leave" }
  | { readonly type: "share"; readonly kind: string; readonly target: "off" | "leaders" | "team" }
  | { readonly type: "exclude"; readonly slug: string; readonly on: boolean }
  | { readonly type: "policy"; readonly requests: "code" | "off" }
  | { readonly type: "code"; readonly days: number; readonly invite: boolean }
  | { readonly type: "grant"; readonly draft: TeamGrantDraft }
  | { readonly type: "revoke"; readonly id: string }
  | { readonly type: "allow"; readonly id: string }
  | { readonly type: "deny"; readonly id: string };

export interface TeamGrantDraft {
  readonly audience: "leaders" | "team" | string;
  readonly capabilities: ReadonlyArray<string>;
  readonly threads: ReadonlyArray<string>;
  readonly preauthorized: ReadonlyArray<string>;
}

/**
 * The grant form: an audience (`leaders`, `team`, or one member's kid), the
 * capabilities ticked, thread ids typed as a comma list (blank = all), and
 * which of the asking capabilities run without a tap. Null when nothing is
 * ticked or the audience is blank.
 */
export function teamGrantDraft(
  audience: string,
  capabilities: ReadonlyArray<string>,
  threadsRaw: string,
  preauthorized: ReadonlyArray<string>,
): TeamGrantDraft | null {
  const who = audience.trim();
  const caps = TEAM_CAPABILITIES.map((c) => c.capability).filter((c) => capabilities.includes(c));
  if (who.length === 0 || who.length > 128 || caps.length === 0) return null;
  const threads = threadsRaw
    .split(",")
    .map((id) => id.trim())
    .filter((id) => id.length > 0 && id.length <= 64 && !id.includes("/"));
  const asking = TEAM_CAPABILITIES.filter((c) => c.asks).map((c) => c.capability);
  return {
    audience: who,
    capabilities: caps,
    threads,
    preauthorized: asking.filter((c) => caps.includes(c) && preauthorized.includes(c)),
  };
}

/** "leaders", "whole team", or the names of the kids a grant names. */
export function teamGrantAudience(
  audience: TeamGrant["audience"],
  members: ReadonlyArray<TeamMember>,
): string {
  if (typeof audience === "string") return audience === "team" ? "whole team" : audience;
  return audience
    .map((kid) => members.find((member) => member.kid === kid)?.name ?? kid)
    .join(", ");
}

/** One line per grant: capabilities, threads, what runs without a tap, expiry. */
export function teamGrantSummary(grant: TeamGrant, nowMs: number): string {
  const parts = [grant.capabilities.join(", ")];
  parts.push(grant.threads === "all" ? "all threads" : `threads ${grant.threads.join(", ")}`);
  if ((grant.preauthorized?.length ?? 0) > 0)
    parts.push(`${grant.preauthorized!.join(", ")} without asking`);
  if (grant.expires !== null && grant.expires !== undefined) {
    const left = grant.expires - Math.floor(nowMs / 1000);
    parts.push(left <= 0 ? "expired" : `expires in ${Math.max(1, Math.floor(left / 60))} min`);
  }
  return parts.join(" · ");
}

/** One line per waiting command: what, where, from whom, how long it keeps. */
export function teamPendingSummary(pending: TeamPending, nowMs: number): string {
  const left = Math.max(0, pending.expires - Math.floor(nowMs / 1000));
  const where = pending.action === "new" ? `in ${pending.project ?? "?"}` : `on ${pending.thread}`;
  const text = pending.text ? ` — "${pending.text}"` : "";
  return `${pending.action} ${where}${text} · ${left}s left`;
}

/** The `infinitus.command` input for one secret-free action. */
export function teamCommandInput(action: TeamAction): InfinitusCommandInput {
  switch (action.type) {
    case "status":
      return { command: "team-status", args: [], options: {} };
    case "fetch":
      return { command: "team-fetch", args: [], options: {} };
    case "publish":
      return { command: "team-publish", args: [], options: {} };
    case "approve":
      return { command: "team-approve", args: [action.kid], options: {} };
    case "decline":
      return { command: "team-decline", args: [action.kid], options: {} };
    case "remove":
      return { command: "team-remove", args: [action.kid], options: {} };
    case "promote":
      return { command: "team-promote", args: [action.kid], options: {} };
    case "leave":
      return { command: "team-leave", args: [], options: { yes: "true" } };
    case "share":
      return { command: "team-share", args: [action.kind, action.target], options: {} };
    case "exclude":
      return {
        command: "team-exclude",
        args: [action.on ? "add" : "remove", action.slug],
        options: {},
      };
    case "policy":
      return { command: "team-policy", args: ["requests", action.requests], options: {} };
    case "code":
      return {
        command: "team-code",
        args: [],
        options: action.invite
          ? { days: String(action.days), invite: "true" }
          : { days: String(action.days) },
      };
    case "grant": {
      const options: Record<string, string> = { cap: action.draft.capabilities.join(",") };
      if (action.draft.threads.length > 0) options.threads = action.draft.threads.join(",");
      if (action.draft.preauthorized.length > 0) options.pre = action.draft.preauthorized.join(",");
      return { command: "team-grant", args: [action.draft.audience], options };
    }
    case "revoke":
      return { command: "team-revoke", args: [action.id], options: {} };
    case "allow":
      return { command: "team-allow", args: [action.id], options: {} };
    case "deny":
      return { command: "team-deny", args: [action.id], options: {} };
  }
}

/** The Mac's roster name for `team-join`, trimmed; null when blank or too long for the secret layer. */
export function teamMemberName(raw: string): string | null {
  const name = raw.trim();
  return name.length === 0 || name.length > 128 ? null : name;
}

/** A project slug for `team-exclude`, trimmed; null when blank, a path or too long. */
export function teamExclusionSlug(raw: string): string | null {
  const slug = raw.trim();
  return slug.length === 0 || slug.length > 128 || slug.includes("/") ? null : slug;
}

/**
 * `team-join` over `infinitus.secret`: the manifest spells its positional
 * `<your name>`, so that is the args key; the code goes on `secret`, never
 * here.
 */
export function teamJoinSecretArgs(name: string): Omit<InfinitusSecretInput, "secret"> {
  return { command: "team-join", args: { "your name": name } };
}

export interface TeamCreateDraft {
  readonly name: string;
  readonly leader: string;
  readonly remote: string;
}

/**
 * The create form's three text fields, trimmed; null when one is blank or
 * longer than the secret layer's 128-character argument cap.
 */
export function teamCreateDraft(
  name: string,
  leader: string,
  remote: string,
): TeamCreateDraft | null {
  const fields = [name.trim(), leader.trim(), remote.trim()];
  if (fields.some((field) => field.length === 0 || field.length > 128)) return null;
  return { name: fields[0]!, leader: fields[1]!, remote: fields[2]! };
}

/**
 * `team-create <name> --remote <url> --as <your name>` over `infinitus.secret`
 * when the remote needs a write token: the manifest's names are the args keys
 * (`name`, `remote`, `as`); the token goes on `secret`, never here.
 */
export function teamCreateSecretArgs(draft: TeamCreateDraft): Omit<InfinitusSecretInput, "secret"> {
  return {
    command: "team-create",
    args: { name: draft.name, remote: draft.remote, as: draft.leader },
  };
}

/** The same verb over `infinitus.command` when there is no token: an ssh remote, or a credential-less one. */
export function teamCreateCommandInput(draft: TeamCreateDraft): InfinitusCommandInput {
  return {
    command: "team-create",
    args: [draft.name],
    options: { remote: draft.remote, as: draft.leader },
  };
}

/** The site's universal link for a code (#1313): the code rides in the fragment, which the site never sees. */
export function teamJoinLink(code: string): string {
  return `https://infinitus.run/join#${encodeURIComponent(code)}`;
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

/** One line per member: role, threads now, today's effort, when they last published, blockers. */
export function teamMemberSummary(member: TeamMember, nowMs: number): string {
  const parts = [teamRoleLabel(member.role)];
  if (member.isMe) parts.push("you");
  const threads = member.threadsNow ?? 0;
  parts.push(
    `${threads} thread${threads === 1 ? "" : "s"} now`,
    `${member.todayMessages ?? 0} messages · ${member.todayCommits ?? 0} commits today`,
    `published ${relativeUnix(member.lastPublished, nowMs)}`,
  );
  if ((member.blockers?.length ?? 0) > 0) parts.push(`blocked: ${member.blockers!.join(", ")}`);
  return parts.join(" · ");
}

/**
 * What a failed `infinitus.secret` says. The server's refusals never reached
 * the socket and get a plain sentence each; anything else is the socket's own
 * wording through `infinitusCommandFailure`.
 */
export function infinitusSecretFailure(cause: Cause.Cause<unknown>): string {
  const error: unknown = Cause.squash(cause);
  if (typeof error === "object" && error !== null && "_tag" in error) {
    const tagged = error as { readonly _tag: unknown; readonly reason?: unknown };
    if (tagged._tag === "InfinitusSecretRefused") {
      switch (tagged.reason) {
        case "no_manifest":
          return "The server has not read the Infinitus command list yet; try again in a moment.";
        case "no_secret":
          return "This Infinitus build does not take the value on its secret channel.";
        case "bad_args":
          return "The server refused the request's arguments.";
        case "too_many_attempts":
          return "Too many attempts; wait a minute and try again.";
        case "scope":
          return "Only the desktop app on the Mac can do this.";
      }
    }
  }
  return infinitusCommandFailure(cause).message;
}
