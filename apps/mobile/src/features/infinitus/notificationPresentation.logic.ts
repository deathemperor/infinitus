import {
  INFINITUS_ACCOUNTS_DEEP_LINK,
  pushPayloadFromRequest,
} from "../agent-awareness/notificationPayload";

/** A notification as expo-notifications hands one to the foreground handler:
    only the request's trigger and data matter here. */
export interface PresentedNotification {
  readonly request: { readonly trigger: unknown; readonly content: { readonly data?: unknown } };
}

/** Whether a notification arriving while the app is open should still show as a banner:
    yes for an Infinitus account alert (deep link Settings › Accounts, #705, #1375) and
    local alarm (`data.infinitus`); no for everything else, keeping T3's own as they are. */
export function presentInForeground(notification: PresentedNotification): boolean {
  const { request } = notification;
  const push = pushPayloadFromRequest(request);
  if (push !== null) return push.deepLink === INFINITUS_ACCOUNTS_DEEP_LINK;
  const data = request.content.data;
  return (
    typeof data === "object" &&
    data !== null &&
    typeof (data as { infinitus?: unknown }).infinitus === "string"
  );
}
