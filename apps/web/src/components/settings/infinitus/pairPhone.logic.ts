import type { DesktopServerExposureState } from "@t3tools/contracts";
import type { InfinitusForkTunnel } from "@t3tools/contracts/infinitus";

import { resolveDesktopPairingUrl } from "../pairingUrls";

/**
 * The "Pair a phone" card on Settings › Infinitus › Devices, as pure state:
 * which tunnel phase to explain, which origin the QR encodes, and where the
 * one-time link is in its life. The card only renders this.
 */

/** The native app's `status.forkTunnel.state` values this page knows. */
export type ForkTunnelPhase =
  | "off"
  | "invalidPort"
  | "blocked"
  | "unavailable"
  | "starting"
  | "up"
  | "stopped";

const KNOWN_PHASES: ReadonlySet<string> = new Set<ForkTunnelPhase>([
  "off",
  "invalidPort",
  "blocked",
  "unavailable",
  "starting",
  "up",
  "stopped",
]);

/** The minted one-time credential as the card holds it. */
export interface PhonePairingLink {
  readonly id: string;
  readonly credential: string;
  readonly expiresAtMs: number;
}

export interface PairPhoneOrigin {
  /** `tunnel`: the Cloudflare hostname; `lan`: the server's address on the
      Mac's own network, which only reaches phones on the same network. */
  readonly kind: "tunnel" | "lan";
  readonly url: string;
}

/** Which origin the card encodes when both are there. */
export type PairPhoneReach = "tunnel" | "lan";

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
  /** `unsupported` is a status without the tunnel (an older build, or the
      Linux tray); `unknown` a state newer than this page. */
  readonly tunnel: ForkTunnelPhase | "unsupported" | "unknown";
  /** What to say about the tunnel while it is not up; null while it is. */
  readonly tunnelNotice: string | null;
  /** What to say about the network side; null while a tunnel link needs no
      caveat. */
  readonly lanNotice: string | null;
  /** Both reaches are available, so the card offers the choice. */
  readonly reachChoice: boolean;
  readonly origin: PairPhoneOrigin | null;
  readonly link: PairPhoneLinkState;
}

const LAN_ONLY_NOTICE = "This link only works for phones on your Wi‑Fi.";
const LAN_UNAVAILABLE_NOTICE =
  "Phones on your Wi‑Fi can pair once Network access is on under Settings › Connections.";

/** The Infinitus build that first reports the tunnel (native #588). */
const FORK_TUNNEL_MIN_BUILD = "3bdc03cca";

function forkTunnelNotice(
  tunnel: InfinitusForkTunnel | undefined,
  phase: PairPhoneCardModel["tunnel"],
): string | null {
  switch (phase) {
    case "up":
      return null;
    case "unsupported":
      return `This Infinitus build has no tunnel (needs ≥ ${FORK_TUNNEL_MIN_BUILD}, on a Mac).`;
    case "off":
      return "Turn on the Cloudflare quick tunnel above to pair a phone off your network.";
    case "invalidPort":
      return `The server port (${tunnel?.port ?? "?"}) is out of range; set it above to the port this server listens on.`;
    case "blocked":
      return "The tunnel stays off for playground and mock instances of Infinitus.";
    case "unavailable":
      return "cloudflared is not installed on the Mac; the tunnel needs it (brew install cloudflared).";
    case "starting":
      return "Starting the tunnel…";
    case "stopped":
      return "The tunnel stopped. Turn it off and on above to start it again.";
    case "unknown":
      return `The tunnel reports a state this page does not know (${tunnel?.state ?? "?"}).`;
  }
}

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
  readonly forkTunnel: InfinitusForkTunnel | undefined;
  /** From `lanPairingOrigin`; null when nothing on the network can be dialled. */
  readonly lanOrigin: string | null;
  /** The user's pick while both reaches are available; ignored otherwise. */
  readonly reach: PairPhoneReach;
  readonly link: PhonePairingLink | null;
  readonly nowMs: number;
}): PairPhoneCardModel {
  const { forkTunnel, lanOrigin, reach, link, nowMs } = input;
  const tunnel: PairPhoneCardModel["tunnel"] =
    forkTunnel === undefined
      ? "unsupported"
      : KNOWN_PHASES.has(forkTunnel.state)
        ? (forkTunnel.state as ForkTunnelPhase)
        : "unknown";
  const tunnelOrigin: PairPhoneOrigin | null =
    tunnel === "up" && forkTunnel?.url !== undefined
      ? { kind: "tunnel", url: forkTunnel.url }
      : null;
  const lan: PairPhoneOrigin | null = lanOrigin === null ? null : { kind: "lan", url: lanOrigin };
  const reachChoice = tunnelOrigin !== null && lan !== null;
  const origin = reachChoice ? (reach === "lan" ? lan : tunnelOrigin) : (tunnelOrigin ?? lan);
  return {
    tunnel,
    tunnelNotice: forkTunnelNotice(forkTunnel, tunnel),
    lanNotice:
      origin === null ? LAN_UNAVAILABLE_NOTICE : origin.kind === "lan" ? LAN_ONLY_NOTICE : null,
    reachChoice,
    origin,
    link: linkState(origin, link, nowMs),
  };
}

function linkState(
  origin: PairPhoneOrigin | null,
  link: PhonePairingLink | null,
  nowMs: number,
): PairPhoneLinkState {
  if (origin === null || link === null) return { kind: "none" };
  const secondsLeft = Math.ceil((link.expiresAtMs - nowMs) / 1000);
  if (secondsLeft <= 0) return { kind: "expired" };
  return {
    kind: "active",
    url: phonePairingUrl(origin.url, link.credential),
    host: new URL(origin.url).host,
    secondsLeft,
  };
}

/** `4:59` — the countdown next to the QR. */
export function formatCountdown(secondsLeft: number): string {
  const seconds = Math.max(0, secondsLeft);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}
