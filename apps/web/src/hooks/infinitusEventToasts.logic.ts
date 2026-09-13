import type { InfinitusEventRow } from "@t3tools/contracts/infinitus";

/** What one event becomes on screen. `kind` is the news it carries. */
export interface EventToast {
  readonly type: "error" | "info";
  readonly title: string;
  readonly description?: string;
  readonly kind: "limit" | "switch";
}

/** The switch line the engine feed writes: "switched a → b". */
const SWITCH_ICON = "arrow.triangle.2.circlepath";
/** The engine's `all-exhausted`, which it re-emits on every re-probe (about
    every ten minutes while every account is dead). */
const EXHAUSTED_ICON = "battery.0percent";

/** The kind an older build's row would have carried, read off its icon
    (native #630 sends `kind` itself; before it only the symbol told). */
function kindFromIcon(icon: string): string | null {
  if (icon === EXHAUSTED_ICON) return "limit";
  if (icon === SWITCH_ICON) return "switch";
  return null;
}

/**
 * The toast for one event, or null for the lines nobody needs interrupting
 * for. The row's `kind` decides (the engine's `all-exhausted` folds to
 * `limit`); a row without one is classified by its SF Symbol. Only account
 * news toasts: a limit and a switch. Every Open goes to /accounts.
 */
export function eventToast(
  event: Pick<InfinitusEventRow, "icon" | "text" | "kind">,
): EventToast | null {
  const kind = event.kind ?? kindFromIcon(event.icon);
  if (kind === "limit") {
    return { type: "error", title: "All accounts exhausted", description: event.text, kind };
  }
  if (kind === "switch") {
    return { type: "info", title: "Switched accounts", description: event.text, kind };
  }
  return null;
}

/** What makes two events the same news: an `all-exhausted` re-emitted every
    re-probe must not stack a toast each time. */
export function eventRepeatKey(event: Pick<InfinitusEventRow, "icon" | "text">): string {
  return `${event.icon}|${event.text}`;
}
