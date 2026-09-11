import { isMacAlertResponse } from "./alertPush.logic";

/** A notification as expo-notifications hands one to the foreground handler:
    only the request's trigger and data matter here. */
export interface PresentedNotification {
  readonly request: { readonly trigger: unknown; readonly content: { readonly data?: unknown } };
}

/** Whether a notification arriving while the app is open should still show
    as a banner: yes for a Mac alert (a push with no data beyond `aps`, #705)
    and for an Infinitus local alarm (`data.infinitus`); no for everything
    else, which keeps T3's own notifications exactly as they are without a
    handler (iOS presents nothing in the foreground then). */
export function presentInForeground(notification: PresentedNotification): boolean {
  if (isMacAlertResponse({ notification })) return true;
  const data = notification.request.content.data;
  return (
    typeof data === "object" &&
    data !== null &&
    typeof (data as { infinitus?: unknown }).infinitus === "string"
  );
}
