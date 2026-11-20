import {
  t3ConnectTroubleshootingUrl,
  type InfinitusConnectTroubleshootingSection,
} from "@infinitus/contracts";
import type { RelayEnvironmentStatusResponse } from "@infinitus/contracts/relay";
import { CONNECT_NAME, PRODUCT_NAME } from "@infinitus/shared/productName";
import * as DateTime from "effect/DateTime";

import type {
  ConnectionAttemptError,
  ConnectionFailureCause,
  ConnectionHop,
  SupervisorConnectionState,
} from "./model.ts";
import { mFallback, msg } from "gt-i18n";
import type { MFunctionType } from "gt-i18n/types";

export type ConnectionHopResult = "ok" | "failed" | "unchecked";

export interface ConnectionDiagnosisHop {
  readonly hop: ConnectionHop;
  readonly label: string;
  readonly result: ConnectionHopResult;
}

export interface ConnectionDiagnosis {
  /** Names the part that failed, e.g. "Mac mini's tunnel is offline". */
  readonly headline: string;
  readonly hops: ReadonlyArray<ConnectionDiagnosisHop>;
  readonly steps: ReadonlyArray<string>;
  readonly facts: ReadonlyArray<readonly [label: string, value: string]>;
  /** The troubleshooting guide section for this failure. Null for direct routes, except a pending T3 Connect sign-in. */
  readonly moreInfoUrl: string | null;
}

export interface ConnectionDiagnosisInput {
  readonly hostLabel: string;
  readonly state: SupervisorConnectionState;
  /** The environment's usual route, used when the failure does not name one. */
  readonly via: "relay" | "direct";
  /** The relay's last health check, which can name a cause before any connect attempt. */
  readonly relayStatus?: Pick<
    RelayEnvironmentStatusResponse,
    "status" | "endpointFailure" | "endpointStatus" | "offlineReason"
  > | null;
  readonly clientVersion?: string | undefined;
  readonly serverVersion?: string | null | undefined;
}

interface Located {
  readonly hop: ConnectionHop;
  readonly cause:
    | ConnectionFailureCause
    | "offline"
    | "outdated"
    | "released"
    | "session_pending"
    | null;
  /** The failure named no hop, so the hops before this one were never probed. */
  readonly guessed?: true;
}

const NOT_ANSWERING: ReadonlySet<ConnectionFailureCause> = new Set([
  "origin_unreachable",
  "invalid_response",
]);

function locate(input: ConnectionDiagnosisInput): Located | null {
  const failure = input.state.lastFailure;
  if (input.state.network === "offline" || input.state.phase === "offline") {
    return { hop: "device", cause: "offline" };
  }
  if (failure?._tag === "ConnectionBlockedError" && failure.serverUpdateRequired) {
    return { hop: "server", cause: "outdated" };
  }
  if (failure?.reason === "session-pending") {
    return { hop: "device", cause: "session_pending" };
  }
  if (failure?.hop !== undefined) {
    return { hop: failure.hop, cause: failure.failureCause ?? null };
  }
  if (failure !== null) {
    const unreachable =
      failure.reason === "network" ||
      failure.reason === "timeout" ||
      failure.reason === "transport";
    const via = failure.via ?? input.via;
    return {
      hop: unreachable && via === "relay" ? "tunnel" : "server",
      cause: null,
      guessed: true,
    };
  }
  const status = input.relayStatus;
  if (status?.status !== "offline") return null;
  if (status.offlineReason === "tunnel_released") return { hop: "tunnel", cause: "released" };
  const cause = status.endpointFailure ?? null;
  return { hop: cause !== null && NOT_ANSWERING.has(cause) ? "server" : "tunnel", cause };
}

function headline(
  host: string,
  located: Located,
  failure: ConnectionAttemptError | null,
  resolve: MFunctionType,
): string {
  switch (located.cause) {
    case "offline":
      return resolve(msg("This device is offline"));
    case "session_pending":
<<<<<<< HEAD
      return `This device is still loading its ${CONNECT_NAME} sign-in`;
=======
      return resolve(msg("This device is still loading its T3 Connect sign-in"));
>>>>>>> upstream-sync-df09ced768-upstream-renamed
    case "approval_pending":
      return resolve(msg("{host} is waiting for someone to approve this device", { host }));
    case "outdated":
<<<<<<< HEAD
      return `${host} runs an older ${PRODUCT_NAME}`;
=======
      return resolve(msg("{host} runs an older T3 Code", { host }));
>>>>>>> upstream-sync-df09ced768-upstream-renamed
    case "clock_skew":
      return resolve(msg("This device's clock is off"));
    case "not_linked":
<<<<<<< HEAD
      return `${host} is not linked to your ${CONNECT_NAME} account`;
    case "relay_error":
      return `${CONNECT_NAME} returned an error`;
=======
      return resolve(msg("{host} is not linked to your T3 Connect account", { host }));
    case "relay_error":
      return resolve(msg("T3 Connect returned an error"));
>>>>>>> upstream-sync-df09ced768-upstream-renamed
    case "tunnel_pending":
      return resolve(msg("{host}'s tunnel is still being set up", { host }));
    case "tunnel_not_enabled":
<<<<<<< HEAD
      return `${CONNECT_NAME} is not turned on for ${host}`;
=======
      return resolve(msg("T3 Connect is not turned on for {host}", { host }));
>>>>>>> upstream-sync-df09ced768-upstream-renamed
    case "released":
    case "tunnel_down":
      return resolve(msg("{host}'s tunnel is offline", { host }));
    case "origin_unreachable":
<<<<<<< HEAD
      return `Tunnel works, but ${PRODUCT_NAME} on ${host} did not answer`;
    case "invalid_response":
      return `${PRODUCT_NAME} on ${host} sent an unexpected answer`;
=======
      return resolve(msg("Tunnel works, but T3 Code on {host} did not answer", { host }));
    case "invalid_response":
      return resolve(msg("T3 Code on {host} sent an unexpected answer", { host }));
>>>>>>> upstream-sync-df09ced768-upstream-renamed
    case "dns":
      return resolve(msg("{host}'s tunnel address did not resolve", { host }));
    case "tls":
      return resolve(msg("Secure connection to {host}'s tunnel failed", { host }));
    case "refused":
      return resolve(msg("{host}'s tunnel refused the connection", { host }));
    case "timeout":
      return resolve(msg("{host} did not answer in time", { host }));
    case "unknown":
    case null:
      break;
  }
  switch (located.hop) {
    case "device":
      return resolve(msg("This device could not prepare the connection"));
    case "relay":
      return failure?.reason === "authentication"
<<<<<<< HEAD
        ? `${CONNECT_NAME} did not accept this device's sign-in`
        : `This device can't reach ${CONNECT_NAME}`;
=======
        ? resolve(msg("T3 Connect did not accept this device's sign-in"))
        : resolve(msg("This device can't reach T3 Connect"));
>>>>>>> upstream-sync-df09ced768-upstream-renamed
    case "tunnel":
      // The relay already reached the host when this device fails on its own.
      return failure?.reason === "network" ||
        failure?.reason === "transport" ||
        failure?.reason === "timeout"
<<<<<<< HEAD
        ? `This device can't reach ${host}'s tunnel`
        : `${CONNECT_NAME} could not reach ${host}'s tunnel`;
    case "server":
      return failure?.reason === "authentication" || failure?.reason === "permission"
        ? `${PRODUCT_NAME} on ${host} did not accept this device`
        : `${PRODUCT_NAME} on ${host} did not answer`;
  }
}

function steps(host: string, located: Located, failure: ConnectionAttemptError | null): string[] {
  const checkHost = `On ${host}, check Settings > Sharing & access or run \`infinitus connect status\`.`;
  switch (located.cause) {
    case "offline":
      return [`Connect this device to the internet. ${PRODUCT_NAME} reconnects on its own.`];
    case "session_pending":
      return [
        `Wait a moment. ${PRODUCT_NAME} retries on its own.`,
        `If it keeps waiting, reload or restart ${PRODUCT_NAME} on this device.`,
=======
        ? resolve(msg("This device can't reach {host}'s tunnel", { host }))
        : resolve(msg("T3 Connect could not reach {host}'s tunnel", { host }));
    case "server":
      return failure?.reason === "authentication" || failure?.reason === "permission"
        ? resolve(msg("T3 Code on {host} did not accept this device", { host }))
        : resolve(msg("T3 Code on {host} did not answer", { host }));
  }
}

function steps(
  host: string,
  located: Located,
  failure: ConnectionAttemptError | null,
  resolve: MFunctionType,
): string[] {
  const checkHost = resolve(
    msg("On {host}, check Settings > Sharing & access or run `t3 connect status`.", { host }),
  );
  switch (located.cause) {
    case "offline":
      return [resolve(msg("Connect this device to the internet. T3 Code reconnects on its own."))];
    case "session_pending":
      return [
        resolve(msg("Wait a moment. T3 Code retries on its own.")),
        resolve(msg("If it keeps waiting, reload or restart T3 Code on this device.")),
>>>>>>> upstream-sync-df09ced768-upstream-renamed
      ];
    case "approval_pending": {
      const code =
        failure?._tag === "ConnectionTransientError" ? failure.verificationCode : undefined;
      return [
        code
          ? resolve(
              msg(
                "On a device already connected to {host}, open Settings > Sharing & access and approve the device showing {code}.",
                { host, code },
              ),
            )
          : resolve(
              msg(
                "On a device already connected to {host}, open Settings > Sharing & access and approve this device.",
                { host },
              ),
            ),
        resolve(
          msg("Or run `t3 auth connect-device approve {code}` on {host}.", {
            code: code ?? "<code>",
            host,
          }),
        ),
      ];
    }
    case "outdated":
<<<<<<< HEAD
      return [`Update ${PRODUCT_NAME} on ${host}.`];
=======
      return [resolve(msg("Update T3 Code on {host}.", { host }))];
>>>>>>> upstream-sync-df09ced768-upstream-renamed
    case "clock_skew":
      return [
        resolve(
          msg("Turn on automatic date and time on this device and on {host}, then retry.", {
            host,
          }),
        ),
      ];
    case "not_linked":
      return [
<<<<<<< HEAD
        `Check that this device is signed in to the same ${CONNECT_NAME} account as the host.`,
        `On ${host}, open Settings > Sharing & access and turn ${CONNECT_NAME} on.`,
      ];
    case "tunnel_pending":
      return [`Wait a minute. ${PRODUCT_NAME} retries on its own.`, checkHost];
    case "relay_error":
      return [
        `Wait a few minutes. ${PRODUCT_NAME} retries on its own.`,
        "If it keeps failing, copy the diagnostics and report it.",
      ];
    case "tunnel_not_enabled":
      return [`On ${host}, open Settings > Sharing & access and turn ${CONNECT_NAME} on.`];
    case "released":
    case "tunnel_down":
      return [
        `Make sure ${host} is awake and ${PRODUCT_NAME} is running on it.`,
=======
        resolve(
          msg("Check that this device is signed in to the same T3 Connect account as the host."),
        ),
        resolve(
          msg("On {host}, open Settings > Sharing & access and turn T3 Connect on.", { host }),
        ),
      ];
    case "tunnel_pending":
      return [resolve(msg("Wait a minute. T3 Code retries on its own.")), checkHost];
    case "relay_error":
      return [
        resolve(msg("Wait a few minutes. T3 Code retries on its own.")),
        resolve(msg("If it keeps failing, copy the diagnostics and report it.")),
      ];
    case "tunnel_not_enabled":
      return [
        resolve(
          msg("On {host}, open Settings > Sharing & access and turn T3 Connect on.", { host }),
        ),
      ];
    case "released":
    case "tunnel_down":
      return [
        resolve(msg("Make sure {host} is awake and T3 Code is running on it.", { host })),
>>>>>>> upstream-sync-df09ced768-upstream-renamed
        checkHost,
        resolve(
          msg(
            "A VPN or Tailscale exit node on {host} can block the tunnel (port 7844). Turn it off or allow the tunnel.",
            { host },
          ),
        ),
      ];
    case "origin_unreachable":
    case "invalid_response":
<<<<<<< HEAD
      return [`Open or restart ${PRODUCT_NAME} on ${host}.`, checkHost];
=======
      return [resolve(msg("Open or restart T3 Code on {host}.", { host })), checkHost];
>>>>>>> upstream-sync-df09ced768-upstream-renamed
    // The relay saw these on its way to the host, so the fix is on the host.
    case "dns":
    case "tls":
    case "refused":
    case "timeout":
    case "unknown":
      return [resolve(msg("Make sure {host} is awake and online.", { host })), checkHost];
    case null:
      break;
  }
  switch (located.hop) {
    case "device":
      return [
<<<<<<< HEAD
        `Restart ${PRODUCT_NAME} on this device.`,
        `If it keeps failing, remove ${host} from this device and add it again.`,
      ];
    case "relay":
      return failure?.reason === "authentication"
        ? [`Sign out of ${CONNECT_NAME} and sign in again.`]
        : [
            "Check this device's internet connection.",
            `A VPN, firewall, or ad blocker on this device can block ${CONNECT_NAME}.`,
=======
        resolve(msg("Restart T3 Code on this device.")),
        resolve(
          msg("If it keeps failing, remove {host} from this device and add it again.", { host }),
        ),
      ];
    case "relay":
      return failure?.reason === "authentication"
        ? [resolve(msg("Sign out of T3 Connect and sign in again."))]
        : [
            resolve(msg("Check this device's internet connection.")),
            resolve(msg("A VPN, firewall, or ad blocker on this device can block T3 Connect.")),
>>>>>>> upstream-sync-df09ced768-upstream-renamed
          ];
    case "tunnel":
      return failure?.reason === "network" ||
        failure?.reason === "transport" ||
        failure?.reason === "timeout"
        ? [
            resolve(msg("A VPN, firewall, or DNS filter on this device can block the tunnel.")),
            resolve(msg("Try another network, or add a direct route such as a Tailscale address.")),
          ]
        : [resolve(msg("Make sure {host} is awake and online.", { host })), checkHost];
    case "server":
<<<<<<< HEAD
      return [
        `Make sure ${PRODUCT_NAME} is running on ${host}.`,
        "Retry. If it keeps failing, copy the diagnostics.",
      ];
=======
      return failure?.reason === "authentication"
        ? [
            resolve(
              msg(
                "This device's sign-in to {host} expired or was revoked. Pair it again with a new pairing link from {host}.",
                { host },
              ),
            ),
          ]
        : [
            resolve(msg("Make sure T3 Code is running on {host}.", { host })),
            resolve(msg("Retry. If it keeps failing, copy the diagnostics.")),
          ];
>>>>>>> upstream-sync-df09ced768-upstream-renamed
  }
}

function helpSection(
  located: Located,
  failure: ConnectionAttemptError | null,
): InfinitusConnectTroubleshootingSection {
  switch (located.cause) {
    case "offline":
      return "this-device-cant-reach-infinitus-connect";
    case "outdated":
      return "the-host-runs-an-older-infinitus";
    case "clock_skew":
      return "the-clock-is-off";
    case "session_pending":
    case "approval_pending":
    case "not_linked":
    case "tunnel_not_enabled":
      return "sign-in-account-or-link-problems";
    case "relay_error":
      return "infinitus-connect-returned-an-error";
    case "released":
    case "tunnel_down":
    case "tunnel_pending":
      return "the-hosts-tunnel-is-offline";
    case "origin_unreachable":
    case "invalid_response":
      return "the-tunnel-works-but-infinitus-does-not-answer";
    case "dns":
    case "tls":
    case "refused":
    case "timeout":
    case "unknown":
      return "the-infinitus-connect-address-does-not-resolve-or-answer";
    case null:
      break;
  }
  const onThisDevice =
    failure?.reason === "network" ||
    failure?.reason === "transport" ||
    failure?.reason === "timeout";
  switch (located.hop) {
    case "device":
      return "this-device-cant-reach-infinitus-connect";
    case "relay":
      return failure?.reason === "authentication"
        ? "sign-in-account-or-link-problems"
        : "this-device-cant-reach-infinitus-connect";
    case "tunnel":
      return onThisDevice
        ? "this-device-cant-reach-infinitus-connect"
        : "the-hosts-tunnel-is-offline";
    case "server":
      return failure?.reason === "authentication" || failure?.reason === "permission"
        ? "sign-in-account-or-link-problems"
        : "the-tunnel-works-but-infinitus-does-not-answer";
  }
}

const T3_CONNECT_NAME = "T3 Connect";

const HOP_ORDER = {
  relay: ["device", "relay", "tunnel", "server"],
  direct: ["device", "server"],
} as const;

function hopLabel(hop: ConnectionHop, host: string, resolve: MFunctionType): string {
  switch (hop) {
    case "device":
      return resolve(msg("This device"));
    case "relay":
<<<<<<< HEAD
      return CONNECT_NAME;
=======
      return T3_CONNECT_NAME;
>>>>>>> upstream-sync-df09ced768-upstream-renamed
    case "tunnel":
      return resolve(msg("{host} tunnel", { host }));
    case "server":
<<<<<<< HEAD
      return `${PRODUCT_NAME} on ${host}`;
=======
      return resolve(msg("T3 Code on {host}", { host }));
>>>>>>> upstream-sync-df09ced768-upstream-renamed
  }
}

/**
 * Turns a connection state into what failed, in order, and what to try. Returns
 * null when nothing has failed. Web and mobile render this same model.
 */
export function presentConnectionDiagnosis(
  input: ConnectionDiagnosisInput,
  resolve: MFunctionType = mFallback,
): ConnectionDiagnosis | null {
  const located = locate(input);
  if (located === null) return null;
  const host = input.hostLabel;
  const failure = input.state.lastFailure;
  const relayPath =
    located.hop === "relay" ||
    located.hop === "tunnel" ||
    (failure === null && input.relayStatus?.status === "offline") ||
    (failure?.via ?? input.via) === "relay";
  const order: ReadonlyArray<ConnectionHop> = HOP_ORDER[relayPath ? "relay" : "direct"];
  const failedIndex = order.indexOf(located.hop);
  const hops = order.map((hop, index): ConnectionDiagnosisHop => ({
    hop,
    label: hopLabel(hop, host, resolve),
    result:
      index === failedIndex
        ? "failed"
        : index < failedIndex && located.guessed !== true
          ? "ok"
          : "unchecked",
  }));

  // The relay health check only explains the state when no attempt has failed yet.
  const httpStatus = failure !== null ? failure.httpStatus : input.relayStatus?.endpointStatus;
  const facts: Array<readonly [string, string]> = [];
  const add = (label: string, value: string | number | null | undefined) => {
    if (value !== null && value !== undefined && value !== "") facts.push([label, String(value)]);
  };
  add(
    resolve(msg("Cause", { $context: "diagnostics field label" })),
    located.cause ?? failure?.reason,
  );
  add(resolve(msg("HTTP status")), httpStatus);
  add(
    resolve(msg("Attempts", { $context: "diagnostics field label" })),
    input.state.attempt > 0 ? input.state.attempt : null,
  );
  add(
    resolve(msg("Next retry")),
    input.state.retryAt === null
      ? null
      : DateTime.formatIso(DateTime.makeUnsafe(input.state.retryAt)),
  );
<<<<<<< HEAD
  add("Route", relayPath ? CONNECT_NAME : "Direct");
  add("App version", input.clientVersion);
  add("Host version", input.serverVersion);
  add("Error", failure?.detail);
  add("Trace ID", failure?.traceId);
=======
  add(
    resolve(msg("Route", { $context: "diagnostics field label" })),
    relayPath ? "T3 Connect" : resolve(msg("Direct", { $context: "connection route" })),
  );
  add(resolve(msg("App version")), input.clientVersion);
  add(resolve(msg("Host version")), input.serverVersion);
  add(resolve(msg("Error", { $context: "diagnostics field label" })), failure?.detail);
  add(resolve(msg("Trace ID")), failure?.traceId);
>>>>>>> upstream-sync-df09ced768-upstream-renamed

  return {
    headline: headline(host, located, failure, resolve),
    hops,
    steps: steps(host, located, failure, resolve),
    facts,
    moreInfoUrl:
      relayPath || located.cause === "session_pending"
        ? t3ConnectTroubleshootingUrl(helpSection(located, failure))
        : null,
  };
}

const HOP_MARK = { ok: "ok", failed: "FAILED", unchecked: "not checked" } as const;

/** One plain-text block for bug reports. */
export function connectionDiagnosisText(hostLabel: string, diagnosis: ConnectionDiagnosis): string {
  return [
    `${PRODUCT_NAME} connection to ${hostLabel}: ${diagnosis.headline}`,
    "",
    ...diagnosis.hops.map((hop) => `${hop.label}: ${HOP_MARK[hop.result]}`),
    "",
    ...diagnosis.facts.map(([label, value]) => `${label}: ${value}`),
    ...(diagnosis.moreInfoUrl ? ["", `More info: ${diagnosis.moreInfoUrl}`] : []),
  ].join("\n");
}
