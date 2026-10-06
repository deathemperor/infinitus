import { DEFAULT_HOSTED_APP_URL } from "./connectAuth.ts";
import { DESKTOP_DEV_URL_SCHEME, DESKTOP_URL_SCHEME } from "./desktopIdentity.ts";
import { isLoopbackHost } from "./preview.ts";

/** Only return to a local client or the hosted client, never an arbitrary OAuth-supplied URL. */
export function providerAuthReturnUrl(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    const desktop =
      [`${DESKTOP_URL_SCHEME}:`, `${DESKTOP_DEV_URL_SCHEME}:`].includes(url.protocol) &&
      url.host === "app";
    const web =
      ["http:", "https:"].includes(url.protocol) &&
      (isLoopbackHost(url.hostname) || url.origin === DEFAULT_HOSTED_APP_URL);
    if (
      url.username ||
      url.password ||
      (!desktop && !web) ||
      (url.pathname !== "/welcome" &&
        url.pathname !== "/settings" &&
        !url.pathname.startsWith("/settings/"))
    )
      return undefined;
    for (const key of Array.from(url.searchParams.keys())) {
      if (
        url.pathname === "/welcome" ||
        !["machine", "project", "checkout", "environmentId", "instanceId"].includes(key)
      ) {
        url.searchParams.delete(key);
      }
    }
    if (url.pathname !== "/welcome" || !/^#agents:[\w-]+$/u.test(url.hash)) url.hash = "";
    return url.toString();
  } catch {
    return undefined;
  }
}
