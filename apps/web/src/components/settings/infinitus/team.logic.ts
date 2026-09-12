import type {
  InfinitusCommandInput,
  InfinitusManifestCommand,
  InfinitusSecretInput,
} from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

import { infinitusCommandFailure } from "./panel.logic";

/**
 * Settings › Infinitus › Team (#747): what the page sends over
 * `infinitus.command` (`team-status`, `team-fetch`, `team-publish`,
 * `team-approve`, `team-decline`) and `infinitus.secret` (`team-join`, the
 * code on the secret channel), and how it reads `team-status`. Pure so the
 * page only renders.
 */

/** A build that answers `team-status` (native #788 for the secret verbs). */
export function teamStatusSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "team-status");
}

/** `team-join` with the code on stdin, which is what opens `infinitus.secret`. */
export function teamJoinSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "team-join" && command.stdin === "secret");
}

/** `team-hostname` with the Cloudflare token on stdin (native #788). */
export function teamHostnameSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "team-hostname" && command.stdin === "secret");
}

/** `team-create` with the remote's write token on stdin (native #788). */
export function teamCreateSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "team-create" && command.stdin === "secret");
}

const TeamMember = Schema.Struct({
  kid: Schema.String,
  name: Schema.String,
  role: Schema.String,
  isMe: Schema.Boolean,
  lastPublished: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  sessionsNow: Schema.optionalKey(Schema.Number),
  blockers: Schema.optionalKey(Schema.Array(Schema.String)),
  todayUSD: Schema.optionalKey(Schema.Number),
  todayMessages: Schema.optionalKey(Schema.Number),
  todayCommits: Schema.optionalKey(Schema.Number),
});
export type TeamMember = typeof TeamMember.Type;

const TeamRequest = Schema.Struct({
  kid: Schema.String,
  name: Schema.String,
  platform: Schema.String,
  devices: Schema.Array(Schema.String),
  at: Schema.Number,
});
export type TeamRequest = typeof TeamRequest.Type;

/** The subset of the Mac's `TeamSnapshot` the page draws; `remote` arrives masked. */
export const TeamStatus = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  remote: Schema.String,
  kid: Schema.String,
  /** "leader" | "member" | "pending" */
  role: Schema.String,
  members: Schema.Array(TeamMember),
  requests: Schema.Array(TeamRequest),
  lastFetch: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  lastPublish: Schema.optionalKey(Schema.NullOr(Schema.Number)),
  lastError: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
export type TeamStatus = typeof TeamStatus.Type;

const decodeTeamStatus = Schema.decodeUnknownOption(TeamStatus);

/**
 * A `team-status` reply: `{ team }` with null when this Mac is in no team
 * (the verb answers `null` then), or null when the shape is not the one above.
 */
export function parseTeamStatus(result: unknown): { readonly team: TeamStatus | null } | null {
  if (result === null || result === undefined) return { team: null };
  const decoded = decodeTeamStatus(result);
  return Option.isNone(decoded) ? null : { team: decoded.value };
}

export type TeamAction =
  | { readonly type: "status" }
  | { readonly type: "fetch" }
  | { readonly type: "publish" }
  | { readonly type: "approve"; readonly kid: string }
  | { readonly type: "decline"; readonly kid: string };

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
  }
}

/** The Mac's roster name for `team-join`, trimmed; null when blank or too long for the secret layer. */
export function teamMemberName(raw: string): string | null {
  const name = raw.trim();
  return name.length === 0 || name.length > 128 ? null : name;
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

export interface TeamHostnameDraft {
  readonly zone: string;
  readonly label: string;
}

/** Zone and label trimmed; null when one is blank or over the secret layer's 128-character cap. */
export function teamHostnameDraft(zone: string, label: string): TeamHostnameDraft | null {
  const fields = [zone.trim(), label.trim()];
  if (fields.some((field) => field.length === 0 || field.length > 128)) return null;
  return { zone: fields[0]!, label: fields[1]! };
}

/**
 * `team-hostname --zone <zone> --label <label>` over `infinitus.secret`: the
 * manifest's option names are the args keys; the Cloudflare API token goes
 * on `secret`, never here.
 */
export function teamHostnameSecretArgs(
  draft: TeamHostnameDraft,
): Omit<InfinitusSecretInput, "secret"> {
  return { command: "team-hostname", args: { zone: draft.zone, label: draft.label } };
}

/** `team-hostname --clear` needs no stdin, so it goes over the plain command. */
export function teamHostnameClearInput(): InfinitusCommandInput {
  return { command: "team-hostname", args: [], options: { clear: "true" } };
}

/** What `team-hostname` answers: the zone and label kept (null after --clear) and whether a token is configured. */
export const TeamHostnameReply = Schema.Struct({
  zone: Schema.NullOr(Schema.String),
  label: Schema.NullOr(Schema.String),
  configured: Schema.Boolean,
});
export type TeamHostnameReply = typeof TeamHostnameReply.Type;

const decodeTeamHostnameReply = Schema.decodeUnknownOption(TeamHostnameReply);

export function parseTeamHostnameReply(result: unknown): TeamHostnameReply | null {
  return Option.getOrNull(decodeTeamHostnameReply(result));
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

/** One line per member: role, sessions now, today's effort. */
export function teamMemberSummary(member: TeamMember, nowMs: number): string {
  const parts = [teamRoleLabel(member.role)];
  if (member.isMe) parts.push("you");
  parts.push(
    `${member.sessionsNow ?? 0} session${(member.sessionsNow ?? 0) === 1 ? "" : "s"} now`,
    `${member.todayMessages ?? 0} messages · ${member.todayCommits ?? 0} commits today`,
    `published ${relativeUnix(member.lastPublished, nowMs)}`,
  );
  if ((member.blockers?.length ?? 0) > 0) parts.push(`blocked: ${member.blockers!.join(", ")}`);
  return parts.join(" · ");
}

/**
 * Session-control grants (#220 phase 2, native PR 4a): who may drive whose
 * sessions, and with which capabilities, without the Mac asking first. Every
 * role but "pending" may manage its own grants over three secret-free verbs.
 */

/** A build that answers all three grant verbs. */
export function teamGrantsSupported(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return ["team-grants", "team-grant", "team-revoke"].every((name) =>
    commands.some((command) => command.name === name),
  );
}

/** The Mac pane's three tiers (#996): `asks` is the tier's note, null for Drive. */
export const TEAM_GRANT_TIERS: ReadonlyArray<{
  readonly name: string;
  readonly capabilities: ReadonlyArray<string>;
  readonly asks: string | null;
}> = [
  { name: "Drive", capabilities: ["view", "send", "approve", "mode", "resume", "key"], asks: null },
  {
    name: "Lifecycle",
    capabilities: ["stop", "resume-past", "delete"],
    asks: "asks you first unless pre-authorised; delete always asks",
  },
  {
    name: "Accounts",
    capabilities: ["swap", "hold"],
    asks: "about this Mac's accounts, not a session; asks you first unless pre-authorised",
  },
];

const TEAM_GRANT_TIER_BY_CAPABILITY = new Map(
  TEAM_GRANT_TIERS.flatMap((tier) =>
    tier.capabilities.map((capability) => [capability, tier] as const),
  ),
);

export const TEAM_GRANT_MEANINGS: Readonly<Record<string, string>> = {
  view: "read the session's live feed",
  send: "type a prompt into the session",
  approve: "answer a tool prompt with Yes or Esc",
  mode: "switch the session's mode",
  resume: "nudge a stalled session",
  key: "press a single key (y, n, 1–9, enter, esc)",
  stop: "stop the session (Esc, then SIGTERM after 5 s)",
  "resume-past": "resume a past session in a new terminal",
  delete: "hide a past session from every list on this Mac (the transcript stays)",
  swap: "switch this Mac's active account",
  hold: "hold or release one of this Mac's accounts",
};

export const TEAM_GRANT_EXPIRY_CHOICES: ReadonlyArray<{
  readonly label: string;
  readonly seconds: number | null;
}> = [
  { label: "Until revoked", seconds: null },
  { label: "1 hour", seconds: 3600 },
  { label: "8 hours", seconds: 28_800 },
  { label: "1 day", seconds: 86_400 },
  { label: "1 week", seconds: 604_800 },
];

/** A capability never held pre-authorised, however the caller asks. */
export const NEVER_PREAUTHORIZED: ReadonlyArray<string> = ["delete"];

const TeamGrantAudience = Schema.Union([
  Schema.Literal("leaders"),
  Schema.Literal("team"),
  Schema.Array(Schema.String),
]);

const TeamGrantSessions = Schema.Union([Schema.Literal("all"), Schema.Array(Schema.String)]);

export const TeamGrant = Schema.Struct({
  id: Schema.String,
  audience: TeamGrantAudience,
  sessions: TeamGrantSessions,
  capabilities: Schema.Array(Schema.String),
  preauthorized: Schema.optionalKey(Schema.Array(Schema.String)),
  since: Schema.Number,
  expires: Schema.optionalKey(Schema.Number),
});
export type TeamGrant = typeof TeamGrant.Type;

const decodeTeamGrant = Schema.decodeUnknownOption(TeamGrant);

/** `team-grant`'s reply: one grant. Null when the shape is not the one above. */
export function parseTeamGrant(result: unknown): TeamGrant | null {
  return Option.getOrNull(decodeTeamGrant(result));
}

const TeamGrantsReply = Schema.Struct({
  grants: Schema.Array(TeamGrant),
});

const decodeTeamGrantsReply = Schema.decodeUnknownOption(TeamGrantsReply);

/** `team-grants`'s reply: every grant. Null when the shape is not the one above. */
export function parseTeamGrants(result: unknown): ReadonlyArray<TeamGrant> | null {
  const decoded = decodeTeamGrantsReply(result);
  return Option.isNone(decoded) ? null : decoded.value.grants;
}

export interface TeamGrantDraft {
  readonly audience: "leaders" | "team" | "members";
  readonly kids: ReadonlyArray<string>;
  readonly capabilities: ReadonlyArray<string>;
  readonly preauthorized: ReadonlyArray<string>;
  /** Empty means all sessions, now and later. */
  readonly sessions: ReadonlyArray<string>;
  readonly expiresSeconds: number | null;
}

/** What stops the form from submitting, or null when the draft is ready. */
export function teamGrantDraftProblem(draft: TeamGrantDraft): string | null {
  if (draft.capabilities.length === 0) return "Pick at least one capability.";
  if (draft.audience === "members" && draft.kids.length === 0) return "Pick at least one member.";
  return null;
}

/** `team-grant <leaders|team|kids…>` over `infinitus.command`. */
export function teamGrantCommandInput(draft: TeamGrantDraft): InfinitusCommandInput {
  const arg =
    draft.audience === "leaders"
      ? "leaders"
      : draft.audience === "team"
        ? "team"
        : draft.kids.join(",");
  const options: Record<string, string> = {
    cap: [...draft.capabilities].sort().join(","),
  };
  const preauthorized = draft.preauthorized.filter(
    (capability) => !NEVER_PREAUTHORIZED.includes(capability),
  );
  if (preauthorized.length > 0) options.pre = [...preauthorized].sort().join(",");
  if (draft.sessions.length > 0) options.sessions = draft.sessions.join(",");
  if (draft.expiresSeconds !== null) options.expires = String(draft.expiresSeconds);
  return { command: "team-grant", args: [arg], options };
}

export function teamRevokeCommandInput(id: string): InfinitusCommandInput {
  return { command: "team-revoke", args: [id], options: {} };
}

export function teamGrantsCommandInput(): InfinitusCommandInput {
  return { command: "team-grants", args: [], options: {} };
}

/** "leaders" / "whole team" / the kids' names, falling back to the kid's first 8 characters. */
export function teamGrantAudienceLabel(
  grant: TeamGrant,
  members: ReadonlyArray<TeamMember>,
): string {
  if (grant.audience === "leaders") return "leaders";
  if (grant.audience === "team") return "whole team";
  return grant.audience
    .map((kid) => members.find((member) => member.kid === kid)?.name ?? kid.slice(0, 8))
    .join(", ");
}

/** "all sessions" / "1 session" / "N sessions". */
export function teamGrantSessionsLabel(grant: TeamGrant): string {
  if (grant.sessions === "all") return "all sessions";
  return grant.sessions.length === 1 ? "1 session" : `${grant.sessions.length} sessions`;
}

/** Capabilities sorted; a Lifecycle/Accounts one carries `(asks)` or `(no ask)`, Drive ones are bare. */
export function teamGrantCapabilitiesLabel(grant: TeamGrant): string {
  const preauthorized = new Set(grant.preauthorized ?? []);
  return [...grant.capabilities]
    .sort()
    .map((capability) => {
      const tier = TEAM_GRANT_TIER_BY_CAPABILITY.get(capability);
      if (tier === undefined || tier.asks === null) return capability;
      return preauthorized.has(capability) ? `${capability} (no ask)` : `${capability} (asks)`;
    })
    .join(", ");
}

/** "until revoked" / "expires in 12 m" / "expires in 2 h 05 m" / "expires in 3 d" / "expired". */
export function teamGrantExpiryLabel(grant: TeamGrant, nowMs: number): string {
  if (grant.expires === undefined) return "until revoked";
  const remaining = grant.expires - Math.floor(nowMs / 1000);
  if (remaining <= 0) return "expired";
  if (remaining < 3600) return `expires in ${Math.floor(remaining / 60)} m`;
  if (remaining < 172_800) {
    const hours = Math.floor(remaining / 3600);
    const minutes = Math.floor((remaining % 3600) / 60);
    return `expires in ${hours} h ${String(minutes).padStart(2, "0")} m`;
  }
  return `expires in ${Math.floor(remaining / 86_400)} d`;
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
      }
    }
  }
  return infinitusCommandFailure(cause).message;
}
