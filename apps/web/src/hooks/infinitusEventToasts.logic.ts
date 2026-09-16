import type { InfinitusEventRow } from "@t3tools/contracts/infinitus";

export interface EventToast {
  readonly type: "error" | "info";
  readonly title: string;
  readonly description?: string;
  readonly kind: "limit" | "switch" | "alert" | "notice";
  /** Worth a desktop banner while the app is away, not just a toast. */
  readonly urgent: boolean;
}

const SWITCH_ICON = "arrow.triangle.2.circlepath";
const EXHAUSTED_ICON = "battery.0percent";

/** Pre-#630 rows carry no kind; only these two were ever worth a toast. */
function kindFromIcon(icon: string): string | null {
  if (icon === EXHAUSTED_ICON) return "limit";
  if (icon === SWITCH_ICON) return "switch";
  return null;
}

/**
 * The app writes an announcement the way `Notifier` splits a banner:
 * `"<headline> — <detail>"`. Same split here, so one line reads the same
 * on both sides.
 */
function split(text: string): { title: string; description?: string } {
  const at = text.indexOf(" — ");
  if (at === -1) return { title: text };
  return { title: text.slice(0, at), description: text.slice(at + 3) };
}

/**
 * What an event is worth interrupting for, or null.
 *
 * Two families. `alert` / `notice` are the app's own announcements
 * (`AppModel.announce`): the Mac decided — under its Notifications prefs and
 * its once-per-episode latches — that this line is worth saying, and stays
 * quiet itself while a desktop is watching, so the row IS the notification
 * and its text is already banner-shaped. `limit` / `switch` are observations
 * the fork has toasted since before that (#630), kept as they were.
 */
export function eventToast(
  event: Pick<InfinitusEventRow, "icon" | "text" | "kind">,
): EventToast | null {
  const kind = event.kind ?? kindFromIcon(event.icon);
  if (kind === "alert") return { type: "error", ...split(event.text), kind, urgent: true };
  if (kind === "notice") return { type: "info", ...split(event.text), kind, urgent: false };
  if (kind === "limit")
    return {
      type: "error",
      title: "All accounts exhausted",
      description: event.text,
      kind,
      urgent: true,
    };
  if (kind === "switch")
    return {
      type: "info",
      title: "Switched accounts",
      description: event.text,
      kind,
      urgent: false,
    };
  return null;
}

export function eventRepeatKey(event: Pick<InfinitusEventRow, "icon" | "text">): string {
  return `${event.icon}|${event.text}`;
}
