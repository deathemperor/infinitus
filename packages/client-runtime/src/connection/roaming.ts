import type { ExecutionEnvironmentDescriptor } from "@infinitus/contracts";
import { deriveWsBaseUrl, normalizeHttpBaseUrl } from "@infinitus/shared/advertisedEndpoint";

import { BearerConnectionProfile } from "./catalog.ts";
import type { ConnectionAttemptError } from "./model.ts";

/**
 * Roaming between a bearer environment's hosts (#663): a phone paired over the
 * LAN keeps the server's tunnel as an alternate and connects through it when
 * the LAN host is unreachable — the same server, the same environment id, the
 * same credential, so nothing re-pairs. Pure rules; the broker applies them.
 */

/** How long a host that is not the only one gets to answer the descriptor
    probe before the walk moves on. The default remote timeout is ten seconds,
    which is the whole wait a phone off the LAN would otherwise sit through. */
export const ROAM_PROBE_TIMEOUT_MS = 3_000;

/**
 * The server's alternates in the phone's own shape: each normalized the way a
 * paired host is (`normalizeHttpBaseUrl` — scheme, host, port, a bare `/`),
 * so `https://code.infinitus.run` and the paired `https://code.infinitus.run/`
 * are one host; the paired host itself and anything unparsable left out; no
 * repeats.
 */
export function normalizedAlternates(
  alternates: ReadonlyArray<string> | undefined,
  pairedHttpBaseUrl: string,
): ReadonlyArray<string> {
  const kept: Array<string> = [];
  for (const raw of alternates ?? []) {
    let host: string;
    try {
      host = normalizeHttpBaseUrl(raw);
    } catch {
      continue;
    }
    if (host !== pairedHttpBaseUrl && !kept.includes(host)) kept.push(host);
  }
  return kept;
}

/**
 * A host any network can dial: an https hostname, the shape every tunnel
 * takes. An IP literal, `localhost` or a `.local` name is one network's
 * address — the LAN's, or a VPN's — and reaches the Mac from nowhere else.
 */
export function isPublicHost(httpBaseUrl: string): boolean {
  let url: URL;
  try {
    url = new URL(httpBaseUrl);
  } catch {
    return false;
  }
  const host = url.hostname;
  return (
    url.protocol === "https:" &&
    host !== "localhost" &&
    !host.endsWith(".local") &&
    !host.startsWith("[") &&
    !/^\d{1,3}(\.\d{1,3}){3}$/.test(host)
  );
}

/** Cloudflare's throwaway quick-tunnel names: handed out afresh on every
    start, so one the server no longer holds may be anyone's. */
const QUICK_TUNNEL_SUFFIX = ".trycloudflare.com";

function isQuickTunnelHost(httpBaseUrl: string): boolean {
  try {
    return new URL(httpBaseUrl).hostname.endsWith(QUICK_TUNNEL_SUFFIX);
  } catch {
    return false;
  }
}

/** The hosts to try, in order: every public host before every private one —
    a phone that knows the Mac's domain dials it from anywhere, on the Wi‑Fi
    too, and a LAN address is only what is left when no tunnel answers.
    Within each class, the one that worked last, then the paired one, then
    the alternates. No repeats, and only hosts the profile still names — a
    last-good host the server has since dropped is not this environment's
    any more and is not tried. */
export function bearerHostOrder(
  profile: Pick<
    BearerConnectionProfile,
    "httpBaseUrl" | "alternateHttpBaseUrls" | "lastGoodHttpBaseUrl"
  >,
): ReadonlyArray<string> {
  const named = [profile.httpBaseUrl, ...(profile.alternateHttpBaseUrls ?? [])];
  const order: Array<string> = [];
  for (const host of [profile.lastGoodHttpBaseUrl, ...named]) {
    if (host !== undefined && host !== "" && named.includes(host) && !order.includes(host)) {
      order.push(host);
    }
  }
  return [...order.filter(isPublicHost), ...order.filter((host) => !isPublicHost(host))];
}

/** Whether a failed host is one to walk past: the Mac is not there. Nothing
    answered (network, timeout), something else did (a café router's page —
    `remote-unavailable` for a non-answer or no JSON; `configuration` for a
    404 or another environment's id). A host that refused the credential
    (authentication, permission) ends the walk — a hop must never hide a
    real refusal. */
export function roamsPast(error: ConnectionAttemptError): boolean {
  switch (error._tag) {
    case "ConnectionTransientError":
      return (
        error.reason === "network" ||
        error.reason === "timeout" ||
        error.reason === "remote-unavailable"
      );
    case "ConnectionBlockedError":
      return error.reason === "configuration";
  }
}

/**
 * The profile after a connect landed on `liveHttpBaseUrl` and read
 * `descriptor`: the live host remembered, the alternates replaced by what the
 * server names now (the paired host itself never listed among them). The
 * server is the authority on its own doors — but it names the tunnel only
 * while the tunnel is up, and a Wi‑Fi connect while the Mac is restarting
 * must not make the phone forget the domain it dials from everywhere else.
 * So a descriptor naming nothing keeps the alternates we have, except a
 * quick-tunnel hostname: one the server no longer holds can be handed to
 * anyone, and the bearer token must never follow it. Null when nothing
 * changed, so the store is not written on every connect.
 */
export function learnedBearerProfile(
  profile: BearerConnectionProfile,
  liveHttpBaseUrl: string,
  descriptor: Pick<ExecutionEnvironmentDescriptor, "alternateHttpBaseUrls">,
): BearerConnectionProfile | null {
  const named = normalizedAlternates(descriptor.alternateHttpBaseUrls, profile.httpBaseUrl);
  const alternates =
    named.length > 0
      ? named
      : (profile.alternateHttpBaseUrls ?? []).filter((host) => !isQuickTunnelHost(host));
  const sameAlternates =
    alternates.length === (profile.alternateHttpBaseUrls ?? []).length &&
    alternates.every((host, index) => profile.alternateHttpBaseUrls?.[index] === host);
  if (sameAlternates && profile.lastGoodHttpBaseUrl === liveHttpBaseUrl) return null;
  return new BearerConnectionProfile({
    connectionId: profile.connectionId,
    environmentId: profile.environmentId,
    label: profile.label,
    httpBaseUrl: profile.httpBaseUrl,
    wsBaseUrl: profile.wsBaseUrl,
    ...(alternates.length === 0 ? {} : { alternateHttpBaseUrls: alternates }),
    lastGoodHttpBaseUrl: liveHttpBaseUrl,
  });
}

/** The socket base for a host the walk lands on. */
export const roamedWsBaseUrl = (httpBaseUrl: string): string => deriveWsBaseUrl(httpBaseUrl);
