import type { InfinitusEventRow } from "@infinitus/contracts/infinitus";

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
  const at = text.search(/ \u2014 /u);
  if (at === -1) return { title: text };
  return { title: text.slice(0, at), description: text.slice(at + 3) };
}

/**
 * What an event is worth interrupting for, or null.
 *
 * `alert` / `notice` are the app's own announcements (`AppModel.announce`): the Mac already decided
 * they merit saying and stays quiet while a desktop watches, so the row is the notification.
 * `limit` / `switch` are older observations (#630).
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
