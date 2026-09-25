import { InfinitusTeamError } from "@infinitus/client-runtime/relay/infinitusTeam";

/**
 * Settings › Team on Infinitus Connect (#1592), the phone's own bits: the
 * site's invite link (App.tsx rewrites it into the `team?code=` route), the
 * roster name and what a failed relay call says. The fold shared with the
 * web pane is `@infinitus/client-runtime/relay/infinitusTeamLogic`.
 */

/** The site's host: a universal link only fires for a host with an AASA. */
export const UNIVERSAL_LINK_HOST = "infinitus.run";
const JOIN_PATH = "/join";

/**
 * The token a team invite link carries: `https://infinitus.run/join#<token>`.
 * The fragment is the whole token, never a query string; null for any other
 * URL or an empty fragment.
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
    url.hostname !== UNIVERSAL_LINK_HOST ||
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

/** Your roster name, trimmed; null when blank or over the relay's 64. */
export function teamMemberName(raw: string): string | null {
  const name = raw.trim();
  return name.length === 0 || name.length > 64 ? null : name;
}

/** "leader" → "Leader". */
export function teamRoleLabel(role: string): string {
  return role.length === 0 ? role : role[0]!.toUpperCase() + role.slice(1);
}

/** What the screen shows for a failed call: the relay's sentence verbatim, a
    trace id on a relay failure, and a plain line for anything else. */
export function teamErrorMessage(error: unknown): string {
  if (error instanceof InfinitusTeamError) {
    return error.kind === "failed" && error.traceId !== null
      ? `${error.message} Trace ID: ${error.traceId}`
      : error.message;
  }
  return error instanceof Error ? error.message : "The request failed.";
}
