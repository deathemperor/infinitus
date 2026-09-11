/**
 * The Devices card's universal pairing link (#724): a Camera scan has to land
 * in this app, and a universal link only fires for a host with an AASA over
 * HTTPS — never the Mac's own tunnel host or LAN address. So the card mints
 * `https://infinitus.run/pair#token=<t>&for=phone&to=<fork origin>` and the
 * phone turns it back into upstream's `<origin>/pair#token=<t>` before the
 * usual parse. Everything after `#` never reaches infinitus.run's server.
 * `to` is accepted as an origin only (scheme + host + port); anything else
 * is refused before a single field is filled.
 */

export const UNIVERSAL_PAIR_HOST = "infinitus.run";
const UNIVERSAL_PAIR_PATH = "/pair";
const PHONE_MARKER = ["for", "phone"] as const;

/** The origin `to` names, when it is exactly one: `http(s)://host[:port]`
    with no path, query, fragment or credentials. */
function originOnly(raw: string | null): string | null {
  if (raw === null) return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (url.username !== "" || url.password !== "") return null;
  if ((url.pathname !== "/" && url.pathname !== "") || url.search !== "" || url.hash !== "") {
    return null;
  }
  return url.origin;
}

/** Whether a URL is the site's `/pair` link, whatever it carries. */
export function isUniversalPairLink(raw: string): boolean {
  try {
    const url = new URL(raw.trim());
    return (
      url.protocol === "https:" &&
      url.hostname === UNIVERSAL_PAIR_HOST &&
      url.pathname.replace(/\/$/, "") === UNIVERSAL_PAIR_PATH
    );
  } catch {
    return false;
  }
}

/**
 * The upstream pairing URL a universal link stands for, or null when the
 * link is not the site's `/pair`, lacks the token or the phone marker, or
 * names a `to` that is not a bare http(s) origin.
 */
export function pairingUrlFromUniversalLink(raw: string): string | null {
  if (!isUniversalPairLink(raw)) return null;
  const url = new URL(raw.trim());
  const fragment = new URLSearchParams(url.hash.replace(/^#/, ""));
  const token = fragment.get("token")?.trim() ?? "";
  if (token.length === 0 || fragment.get(PHONE_MARKER[0]) !== PHONE_MARKER[1]) return null;
  const origin = originOnly(fragment.get("to"));
  if (origin === null) return null;
  const target = new URL(`${origin}/pair`);
  target.hash = new URLSearchParams([
    ["token", token],
    [PHONE_MARKER[0], PHONE_MARKER[1]],
  ]).toString();
  return target.toString();
}

/** A pairing link as the parser wants it: a universal link rewritten to its
    origin's `/pair`, anything else untouched. */
export function resolvePairingLink(raw: string): string {
  return pairingUrlFromUniversalLink(raw) ?? raw;
}
