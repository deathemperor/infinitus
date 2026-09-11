/** The APNs device token as expo-notifications hands it over, or null when the
    platform, shape or emptiness says there is none to register. */
export function deviceTokenOf(
  token: { readonly type: string; readonly data: unknown } | null | undefined,
  os: string,
): string | null {
  if (token === null || token === undefined || token.type !== os) return null;
  if (typeof token.data !== "string") return null;
  const trimmed = token.data.trim();
  return trimmed.length === 0 ? null : trimmed;
}

/** A tapped notification that came from a Mac's `pushAlert`: delivered over
    push with no custom data (iOS keeps the payload's `aps` under `data`, so
    that key alone still counts as none). T3's agent pushes carry their own
    keys and the reset alarms are local, so neither matches. */
export function isMacAlertResponse(response: {
  readonly notification: {
    readonly request: { readonly trigger: unknown; readonly content: { readonly data?: unknown } };
  };
}): boolean {
  const { trigger, content } = response.notification.request;
  if (typeof trigger !== "object" || trigger === null) return false;
  if ((trigger as { type?: unknown }).type !== "push") return false;
  const data = content.data;
  if (data === null || data === undefined) return true;
  if (typeof data !== "object") return false;
  return Object.keys(data).every((key) => key === "aps");
}
