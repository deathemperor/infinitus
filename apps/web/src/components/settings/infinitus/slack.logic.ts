import type { InfinitusSlackSettings } from "@t3tools/contracts";

/**
 * Slack bridge settings (#574, PR 3): the pure half of the card. The two
 * tokens never reach the client: the server sends a marker for a stored
 * token and "" for none, and takes the marker back as "keep", "" as "clear"
 * and anything else as a new value — so the card only ever knows whether a
 * token is set, and sends what was typed once.
 */

export type SlackTokenField = "appToken" | "botToken";

export function slackTokenSet(value: string): boolean {
  return value.length > 0;
}

/** The patch for a typed value: trimmed, or "" to clear; null when nothing was typed. */
export function slackTokenPatch(draft: string): string | null {
  const trimmed = draft.trim();
  return trimmed.length === 0 ? null : trimmed;
}

/** Member ids as typed (commas, spaces or lines), deduped, order kept. */
export function parseAllowedUserIds(text: string): ReadonlyArray<string> {
  const seen = new Set<string>();
  for (const raw of text.split(/[\s,]+/)) {
    const id = raw.trim();
    if (id.length > 0) seen.add(id);
  }
  return [...seen];
}

/** One line on what the bridge will do with the settings as they are. */
export function slackStatusLine(settings: InfinitusSlackSettings): string {
  if (!settings.enabled) return "Off.";
  const missing: string[] = [];
  if (!slackTokenSet(settings.appToken)) missing.push("the app token");
  if (!slackTokenSet(settings.botToken)) missing.push("the bot token");
  if (settings.allowedUserIds.length === 0) missing.push("an allowed member");
  if (missing.length > 0)
    return `Inert until ${missing.join(", ")} ${missing.length === 1 ? "is" : "are"} set.`;
  const count = settings.allowedUserIds.length;
  return `On for ${count} ${count === 1 ? "member" : "members"}.`;
}
