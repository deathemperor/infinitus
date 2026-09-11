import type { ExecutionEnvironmentDescriptor } from "@t3tools/contracts";
import { deriveWsBaseUrl } from "@t3tools/shared/advertisedEndpoint";

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

/** The hosts to try, in order: the one that worked last (it is the paired one
    until a roam), then the paired one, then the alternates. No repeats. */
export function bearerHostOrder(
  profile: Pick<
    BearerConnectionProfile,
    "httpBaseUrl" | "alternateHttpBaseUrls" | "lastGoodHttpBaseUrl"
  >,
): ReadonlyArray<string> {
  const order: Array<string> = [];
  for (const host of [
    profile.lastGoodHttpBaseUrl,
    profile.httpBaseUrl,
    ...(profile.alternateHttpBaseUrls ?? []),
  ]) {
    if (host !== undefined && host !== "" && !order.includes(host)) order.push(host);
  }
  return order;
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
 * `descriptor`: the live host remembered, the alternates re-learned from the
 * server (the paired host itself never listed among them). A descriptor that
 * names none leaves the known alternates alone — the tunnel is down for the
 * moment, not gone, and a stale one costs one short probe. Null when nothing
 * changed, so the store is not written on every connect.
 */
export function learnedBearerProfile(
  profile: BearerConnectionProfile,
  liveHttpBaseUrl: string,
  descriptor: Pick<ExecutionEnvironmentDescriptor, "alternateHttpBaseUrls">,
): BearerConnectionProfile | null {
  const named = (descriptor.alternateHttpBaseUrls ?? []).filter(
    (host) => host !== profile.httpBaseUrl,
  );
  const alternates = named.length === 0 ? (profile.alternateHttpBaseUrls ?? []) : named;
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
