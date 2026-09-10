import type { InfinitusEventRow } from "@t3tools/contracts/infinitus";

/** What one event becomes on screen. `action` names the one follow-up a
    toast can offer: opening the app's pop-out on the Infinitus host. */
export interface EventToast {
  readonly type: "error" | "warning" | "info";
  readonly title: string;
  readonly description?: string;
  readonly action?: "show-popout";
}

/** The switch line the engine feed writes: "switched a → b". */
const SWITCH_ICON = "arrow.triangle.2.circlepath";
/** The engine's `all-exhausted`, which it re-emits on every re-probe (about
    every ten minutes while every account is dead). */
const EXHAUSTED_ICON = "battery.0percent";
/** Shared by "no switch — …" (every minute, noise) and "headless session N is
    waiting for an answer"; only the text tells them apart. */
const HAND_ICON = "hand.raised";
const WAITING_PREFIX = "headless session ";
const WAITING_SUFFIX = " is waiting for an answer";

/**
 * The toast for one event, or null for the lines nobody needs interrupting
 * for. The reply carries no `kind` (#615), so this reads the SF Symbol and,
 * where one symbol serves two lines, the text.
 */
export function eventToast(event: Pick<InfinitusEventRow, "icon" | "text">): EventToast | null {
  if (event.icon === EXHAUSTED_ICON) {
    return { type: "error", title: "All accounts exhausted", description: event.text };
  }
  if (event.icon === SWITCH_ICON) {
    return { type: "info", title: "Switched accounts", description: event.text };
  }
  if (
    event.icon === HAND_ICON &&
    event.text.startsWith(WAITING_PREFIX) &&
    event.text.endsWith(WAITING_SUFFIX)
  ) {
    return {
      type: "warning",
      title: "A session is waiting for you",
      description: event.text,
      action: "show-popout",
    };
  }
  return null;
}

/** What makes two events the same news: an `all-exhausted` re-emitted every
    re-probe must not stack a toast each time. */
export function eventRepeatKey(event: Pick<InfinitusEventRow, "icon" | "text">): string {
  return `${event.icon}|${event.text}`;
}
