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
  /** `tunnel`: the Cloudflare hostname; `lan`: the page's own non-loopback
      origin, which only reaches phones on the same network. */
  readonly kind: "tunnel" | "lan";
  readonly url: string;
}

export type PairPhoneLinkState =
  | { readonly kind: "none" }
  | { readonly kind: "active"; readonly url: string; readonly secondsLeft: number }
  | { readonly kind: "expired" };

export interface PairPhoneCardModel {
  /** `unsupported` is a status without the tunnel (an older build, or the
      Linux tray); `unknown` a state newer than this page. */
  readonly tunnel: ForkTunnelPhase | "unsupported" | "unknown";
  /** What to say about the tunnel while it is not up; null while it is. */
  readonly tunnelNotice: string | null;
  readonly origin: PairPhoneOrigin | null;
  readonly link: PairPhoneLinkState;
}

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
      return `This Infinitus build has no fork tunnel (needs ≥ ${FORK_TUNNEL_MIN_BUILD}, on a Mac).`;
    case "off":
      return "Turn on the Cloudflare quick tunnel above to pair a phone off your network.";
    case "invalidPort":
      return `The fork server port (${tunnel?.port ?? "?"}) is out of range; set it above to the port this server listens on.`;
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

/** The phone's pairing URL for an origin: upstream's `/pair` page with the
    token in the fragment, which the phone app and a phone browser both read. */
export function phonePairingUrl(originUrl: string, credential: string): string {
  return resolveDesktopPairingUrl(originUrl, credential);
}

export function pairPhoneCardModel(input: {
  readonly forkTunnel: InfinitusForkTunnel | undefined;
  /** The page's own origin when it is not loopback, else null: a phone can
      dial a LAN origin but never the Mac's loopback. */
  readonly pageOrigin: string | null;
  readonly link: PhonePairingLink | null;
  readonly nowMs: number;
}): PairPhoneCardModel {
  const { forkTunnel, pageOrigin, link, nowMs } = input;
  const tunnel: PairPhoneCardModel["tunnel"] =
    forkTunnel === undefined
      ? "unsupported"
      : KNOWN_PHASES.has(forkTunnel.state)
        ? (forkTunnel.state as ForkTunnelPhase)
        : "unknown";
  const origin: PairPhoneOrigin | null =
    tunnel === "up" && forkTunnel?.url !== undefined
      ? { kind: "tunnel", url: forkTunnel.url }
      : pageOrigin !== null
        ? { kind: "lan", url: pageOrigin }
        : null;
  return {
    tunnel,
    tunnelNotice: forkTunnelNotice(forkTunnel, tunnel),
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
  return { kind: "active", url: phonePairingUrl(origin.url, link.credential), secondsLeft };
}

/** `4:59` — the countdown next to the QR. */
export function formatCountdown(secondsLeft: number): string {
  const seconds = Math.max(0, secondsLeft);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}
