import { INFINITUS_ACCOUNTS_DEEP_LINK } from "../agent-awareness/notificationPayload";

/** A notification as expo-notifications hands one to the foreground handler:
    only the request's trigger and data matter here. */
export interface PresentedNotification {
  readonly request: { readonly trigger: unknown; readonly content: { readonly data?: unknown } };
}

/** Whether a notification arriving while the app is open should still show
    as a banner: yes for an Infinitus account alert (a push whose deep link is
    Settings › Accounts, #705, #1375) and for an Infinitus local alarm
    (`data.infinitus`); no for everything else, which keeps T3's own
    notifications exactly as they are without a handler (iOS presents nothing
    in the foreground then). */
export function presentInForeground(notification: PresentedNotification): boolean {
  const { trigger, content } = notification.request;
  const data = content.data;
  if (typeof data !== "object" || data === null) return false;
  const { deepLink, infinitus } = data as { deepLink?: unknown; infinitus?: unknown };
  if (
    typeof trigger === "object" &&
    trigger !== null &&
    (trigger as { type?: unknown }).type === "push" &&
    deepLink === INFINITUS_ACCOUNTS_DEEP_LINK
  ) {
    return true;
  }
  return typeof infinitus === "string";
}
