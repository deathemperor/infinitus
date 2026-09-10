import type { InfinitusEventRow, InfinitusManifestCommand } from "@t3tools/contracts/infinitus";

/** What one event becomes on screen. `action` names the one follow-up a
    toast can offer: opening the waiting session's window on the Infinitus
    host — `pid` is the session the event names, when its text carries one. */
export interface EventToast {
  readonly type: "error" | "warning" | "info";
  readonly title: string;
  readonly description?: string;
  readonly action?: "show-popout";
  readonly pid?: number;
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

/** The kind an older build's row would have carried, read off its icon
    (native #630 sends `kind` itself; before it only the symbol told). */
function kindFromIcon(icon: string): string | null {
  if (icon === EXHAUSTED_ICON) return "limit";
  if (icon === SWITCH_ICON) return "switch";
  if (icon === HAND_ICON) return "other";
  return null;
}

/**
 * The toast for one event, or null for the lines nobody needs interrupting
 * for. The row's `kind` decides (the engine's `all-exhausted` folds to
 * `limit`); a row without one is classified by its SF Symbol. The waiting
 * session is logged as `other`, so its text is what tells it from the
 * per-minute "no switch" line under the same symbol.
 */
export function eventToast(
  event: Pick<InfinitusEventRow, "icon" | "text" | "kind">,
): EventToast | null {
  const kind = event.kind ?? kindFromIcon(event.icon);
  if (kind === "limit") {
    return { type: "error", title: "All accounts exhausted", description: event.text };
  }
  if (kind === "switch") {
    return { type: "info", title: "Switched accounts", description: event.text };
  }
  if (
    kind === "other" &&
    event.text.startsWith(WAITING_PREFIX) &&
    event.text.endsWith(WAITING_SUFFIX)
  ) {
    const pid = Number(event.text.slice(WAITING_PREFIX.length, -WAITING_SUFFIX.length));
    return {
      type: "warning",
      title: "A session is waiting for you",
      description: event.text,
      action: "show-popout",
      ...(Number.isInteger(pid) && pid > 0 ? { pid } : {}),
    };
  }
  return null;
}

/** The Show action's command: the session's own window (`show session <pid>`,
    #612) when the toast names a session and this build's `show` takes one, else
    the pop-out. */
export function showCommandArgs(
  toast: Pick<EventToast, "pid">,
  commands: ReadonlyArray<Pick<InfinitusManifestCommand, "name" | "args">>,
): ReadonlyArray<string> {
  const show = commands.find((command) => command.name === "show");
  const hasSession = show !== undefined && show.args.some((arg) => arg.includes("session"));
  return toast.pid !== undefined && hasSession ? ["session", String(toast.pid)] : ["popout"];
}

/** What makes two events the same news: an `all-exhausted` re-emitted every
    re-probe must not stack a toast each time. */
export function eventRepeatKey(event: Pick<InfinitusEventRow, "icon" | "text">): string {
  return `${event.icon}|${event.text}`;
}
