import type { DesktopServerExposureState } from "@infinitus/contracts";

import { resolveDesktopPairingUrl } from "../pairingUrls";

/**
 * The "Pair a phone" card on Settings › Infinitus › Devices, as pure state:
 * which address on the Mac's Wi‑Fi the QR encodes, and where the one-time
 * link is in its life. The card only renders this.
 *
 * This pairs a phone that is on the Mac's own network. Off it, the phone
 * reaches this environment through Infinitus Connect — the Mac's Cloudflare
 * tunnels retired when Connect took that job over.
 */

/** The minted one-time credential as the card holds it. */
export interface PhonePairingLink {
  readonly id: string;
  readonly credential: string;
  readonly expiresAtMs: number;
}

export type PairPhoneLinkState =
  | { readonly kind: "none" }
  | {
      readonly kind: "active";
      readonly url: string;
      /** `host[:port]` of the origin, for typing into the phone's Host field. */
      readonly host: string;
      readonly secondsLeft: number;
    }
  | { readonly kind: "expired" };

export interface PairPhoneCardModel {
  /** What to say about the network this link reaches over. */
  readonly lanNotice: string;
  /** The LAN origin the QR encodes; null when nothing on the network can be
      dialled, in which case there is no link to draw. */
  readonly origin: string | null;
  readonly link: PairPhoneLinkState;
}

const LAN_ONLY_NOTICE =
  "This link only works for phones on your Wi‑Fi. Off it, link this environment to Infinitus Connect under Settings › Connections and the phone reaches it from anywhere.";
const LAN_UNAVAILABLE_NOTICE =
  "Phones on your Wi‑Fi can pair once Network access is on under Settings › Connections. Off it, link this environment to Infinitus Connect there instead.";

/** Marks a pairing link as minted for the phone app: `#token=…&for=phone`.
    The phone reads the token as before (`URLSearchParams` on the fragment);
    the browser's `/pair` page sees the marker and refuses to spend the token
    on itself (#724 — a link that lands in Safari would otherwise pair the
    browser and strand the phone). */
const PHONE_LINK_PARAM = "for";
const PHONE_LINK_VALUE = "phone";
/** The origin the site's link hands the phone: the Mac's tunnel or LAN
    address, in the fragment the site's server never sees. */
const PHONE_LINK_ORIGIN_PARAM = "to";

/** The site's `/pair`, a universal link into the phone app (#724): the only
    host with an AASA the app can claim — the Mac's own origin never is. */
const UNIVERSAL_PAIR_URL = "https://infinitus.run/pair";

/** Where a phone user scans from. */
export const SCAN_IN_APP_NOTICE =
  "Scan with the Camera app on a phone that has Infinitus, or from inside the app: Settings › Configuration › Environments › Add › Scan QR. In a browser the link only explains; the code stays unused.";

/** The phone's pairing URL for an origin: the site's universal link with the
    token, the phone marker and the Mac's origin all in the fragment. The app
    rebuilds upstream's `<origin>/pair#token=…` from it (#746's prefill); an
    app-less phone lands on the site's forwarder, then on `<origin>/pair`,
    where the marker keeps the token unspent. */
export function phonePairingUrl(originUrl: string, credential: string): string {
  const target = new URL(resolveDesktopPairingUrl(originUrl, credential));
  const hash = new URLSearchParams(target.hash.replace(/^#/, ""));
  hash.set(PHONE_LINK_PARAM, PHONE_LINK_VALUE);
  hash.set(PHONE_LINK_ORIGIN_PARAM, target.origin);
  const url = new URL(UNIVERSAL_PAIR_URL);
  url.hash = hash.toString();
  return url.toString();
}

/** A link the Devices card minted for the phone, landing in a browser. */
export function isPhonePairingLink(url: URL): boolean {
  return new URLSearchParams(url.hash.replace(/^#/, "")).get(PHONE_LINK_PARAM) === PHONE_LINK_VALUE;
}

/**
 * The origin a phone on the Mac's Wi‑Fi can dial: the desktop server's
 * advertised LAN address while its Network access is on, else the first
 * address the server itself reports (`lanHttpBaseUrls`, #651 — a browser or
 * a dev server has no desktop bridge), else the page's own origin when that
 * is not loopback. A phone can never dial the Mac's loopback, so a
 * loopback-only setup yields null.
 */
export function lanPairingOrigin(input: {
  readonly serverExposure: DesktopServerExposureState | null;
  readonly serverLanOrigins: ReadonlyArray<string>;
  readonly pageOrigin: string | null;
}): string | null {
  const exposure = input.serverExposure;
  if (exposure?.mode === "network-accessible" && exposure.endpointUrl !== null) {
    return exposure.endpointUrl;
  }
  return input.serverLanOrigins[0] ?? input.pageOrigin;
}

export function pairPhoneCardModel(input: {
  /** From `lanPairingOrigin`; null when nothing on the network can be dialled. */
  readonly lanOrigin: string | null;
  readonly link: PhonePairingLink | null;
  readonly nowMs: number;
}): PairPhoneCardModel {
  const { lanOrigin, link, nowMs } = input;
  return {
    lanNotice: lanOrigin === null ? LAN_UNAVAILABLE_NOTICE : LAN_ONLY_NOTICE,
    origin: lanOrigin,
    link: linkState(lanOrigin, link, nowMs),
  };
}

function linkState(
  origin: string | null,
  link: PhonePairingLink | null,
  nowMs: number,
): PairPhoneLinkState {
  if (origin === null || link === null) return { kind: "none" };
  const secondsLeft = Math.ceil((link.expiresAtMs - nowMs) / 1000);
  if (secondsLeft <= 0) return { kind: "expired" };
  return {
    kind: "active",
    url: phonePairingUrl(origin, link.credential),
    host: new URL(origin).host,
    secondsLeft,
  };
}

/** `4:59` — the countdown next to the QR. */
export function formatCountdown(secondsLeft: number): string {
  const seconds = Math.max(0, secondsLeft);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}
