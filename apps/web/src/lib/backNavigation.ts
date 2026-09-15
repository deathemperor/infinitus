/**
 * The pages whose sidebar header shows a back arrow (fork #840): settings,
 * a project's settings, and the whole-app pages. The mouse's back button
 * (Chromium `button` 3) navigates back on these and nowhere else; a thread
 * is left alone so a stray click never leaves the conversation.
 */
export function isBackablePathname(pathname: string): boolean {
  if (/^\/settings(?:\/|$)/.test(pathname)) return true;
  if (/^\/projects\/[^/]+\/?$/.test(pathname)) return true;
  return BACKABLE_PAGES.has(pathname);
}

const BACKABLE_PAGES: ReadonlySet<string> = new Set([
  "/usage",
  "/pull-requests",
  "/accounts",
  "/stats",
  "/activity",
  "/utilization",
]);

/** Chromium's `MouseEvent.button` for a mouse's back and forward buttons. */
const MOUSE_BACK_BUTTON = 3;
const MOUSE_FORWARD_BUTTON = 4;

export type MouseHistoryIntent = "back" | "forward" | null;

/** What a mouse button release asks of the app's history: back only on a
    backable page, forward anywhere (a no-op when nothing is ahead). */
export function mouseHistoryIntent(button: number, pathname: string): MouseHistoryIntent {
  if (button === MOUSE_FORWARD_BUTTON) return "forward";
  if (button === MOUSE_BACK_BUTTON && isBackablePathname(pathname)) return "back";
  return null;
}

/** The two directions of macOS's navigate-back/forward gesture: a trackpad's
    "Swipe between pages", or a mouse driver (Logi Options+) that maps the
    mouse's back/forward buttons to it instead of to Chromium buttons 3/4
    (#1250). Left = back, right = forward: #1250 guessed the opposite and was
    never checked on hardware, so the back button read as forward and did
    nothing. Every gesture Options+ sent for the back button arrived as
    `left`. */
export type HistoryGestureDirection = "left" | "right";

/** What a navigation gesture asks of the app's history: the mouse buttons'
    rule with the direction in place of the button. */
export function swipeHistoryIntent(
  direction: HistoryGestureDirection,
  pathname: string,
): MouseHistoryIntent {
  if (direction === "right") return "forward";
  return isBackablePathname(pathname) ? "back" : null;
}
