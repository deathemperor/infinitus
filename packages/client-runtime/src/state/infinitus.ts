import { WS_METHODS } from "@t3tools/contracts";
import type {
  InfinitusAccount,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import type { Atom } from "effect/unstable/reactivity";

import {
  createEnvironmentRpcCommand,
  createEnvironmentRpcQueryAtomFamily,
  createEnvironmentSubscriptionAtomFamily,
} from "./runtime.ts";
import type { EnvironmentRegistry } from "../connection/registry.ts";
import { subscribe, type EnvironmentRpcInput } from "../rpc/client.ts";

// The server holds one snapshot per environment and only polls the control
// socket while a client watches, so a released view keeps its stream briefly
// rather than paying for a fresh poll when the user comes back.
const INFINITUS_SNAPSHOT_IDLE_TTL_MS = 60_000;
/** The Stats page's read (#659): `stats --period p` re-read every 5 min while
    a page holds the atom (native's own rescan cadence under a `stats` lease —
    faster only re-reads the same fold), stale after a minute, and gone a
    minute after the last page leaves so nothing is requested unmounted. */
const INFINITUS_STATS_STALE_MS = 60_000;
const INFINITUS_STATS_REFRESH_MS = 300_000;
const INFINITUS_STATS_IDLE_TTL_MS = 60_000;
/** The Activity page's read (#659): `events --limit 100` once on mount; the
    snapshot subscription's deltas carry everything after. No re-read. */
const INFINITUS_EVENTS_STALE_MS = 60_000;
const INFINITUS_EVENTS_IDLE_TTL_MS = 60_000;
/** The Machine page's read (#659): `machine` re-read every minute while a
    page holds the atom (native samples at most once per 55 s, so faster only
    re-reads the same report), stale after 30 s so a remount inside the
    minute shows the held report, and dropped a minute after the page leaves.
    A manual refresh — the button, the page's 5 s retry while native is
    still sampling — always reads (`Atom.swr`'s refresh is forceful). */
const INFINITUS_MACHINE_STALE_MS = 30_000;
const INFINITUS_MACHINE_REFRESH_MS = 60_000;
const INFINITUS_MACHINE_IDLE_TTL_MS = 60_000;
const INFINITUS_PAIRING_IDLE_TTL_MS = 1_000;

/** What a fleet row shows for an account: its alias, else the email it signed
    in with, else the number the engine knows it by. */
export function infinitusAccountLabel(account: InfinitusAccount): string {
  if (account.alias !== undefined && account.alias !== "") return account.alias;
  if (account.email !== "") return account.email;
  return `#${account.number}`;
}

/** The account a fleet is currently using. `activeNumber` is the engine's own
    answer; the per-account `active` flag is the fallback for engines that do
    not report one. */
export function infinitusActiveAccount(fleet: InfinitusFleet): InfinitusAccount | null {
  const byNumber = fleet.accounts.find((account) => account.number === fleet.activeNumber);
  if (byNumber !== undefined) return byNumber;
  return fleet.accounts.find((account) => account.active) ?? null;
}

/** The fleet a fleet-targeting command's `<fleet>` names, or null while the
    snapshot is still loading or the engine is gone. */
export function infinitusFleetByKey(
  snapshot: InfinitusSnapshot | null,
  key: string,
): InfinitusFleet | null {
  return snapshot?.fleets.find((fleet) => fleet.key === key) ?? null;
}

export function createInfinitusEnvironmentAtoms<R, E>(
  runtime: Atom.AtomRuntime<EnvironmentRegistry | R, E>,
) {
  return {
    // The stream carries whole snapshots, so the atom's value is simply the
    // latest one the server sent.
    snapshot: createEnvironmentSubscriptionAtomFamily(runtime, {
      label: "environment-data:infinitus:snapshot",
      idleTtlMs: INFINITUS_SNAPSHOT_IDLE_TTL_MS,
      subscribe: (input: EnvironmentRpcInput<typeof WS_METHODS.subscribeInfinitus>) =>
        subscribe(WS_METHODS.subscribeInfinitus, input),
    }),
    // No invalidation hook: the server refreshes its snapshot after a write and
    // the subscription delivers the new one.
    command: createEnvironmentRpcCommand(runtime, {
      label: "environment-data:infinitus:command",
      tag: WS_METHODS.infinitusCommand,
    }),
    // The app coming up shows through the snapshot subscription, so nothing
    // to invalidate here either.
    launch: createEnvironmentRpcCommand(runtime, {
      label: "environment-data:infinitus:launch",
      tag: WS_METHODS.infinitusLaunch,
    }),
    // "Run now" for a held thread (#616): the released marker row and the
    // session starting show through the thread's own subscription.
    /** The threads held for headroom (#741): whole lists, so the atom's
        value is the latest one. Same idle grace as the snapshot. */
    holds: createEnvironmentSubscriptionAtomFamily(runtime, {
      label: "environment-data:infinitus:holds",
      idleTtlMs: INFINITUS_SNAPSHOT_IDLE_TTL_MS,
      subscribe: (input: EnvironmentRpcInput<typeof WS_METHODS.subscribeInfinitusHolds>) =>
        subscribe(WS_METHODS.subscribeInfinitusHolds, input),
    }),
    releaseThread: createEnvironmentRpcCommand(runtime, {
      label: "environment-data:infinitus:releaseThread",
      tag: WS_METHODS.infinitusReleaseThread,
    }),
    // A read verb as a query: the same forward as `command`, held and re-read
    // only while a page subscribes. Keyed by its whole input, so each period
    // is its own atom.
    events: createEnvironmentRpcQueryAtomFamily(runtime, {
      label: "environment-data:infinitus:events",
      tag: WS_METHODS.infinitusCommand,
      staleTimeMs: INFINITUS_EVENTS_STALE_MS,
      idleTtlMs: INFINITUS_EVENTS_IDLE_TTL_MS,
    }),
    stats: createEnvironmentRpcQueryAtomFamily(runtime, {
      label: "environment-data:infinitus:stats",
      tag: WS_METHODS.infinitusCommand,
      staleTimeMs: INFINITUS_STATS_STALE_MS,
      refreshIntervalMs: INFINITUS_STATS_REFRESH_MS,
      idleTtlMs: INFINITUS_STATS_IDLE_TTL_MS,
    }),
    machine: createEnvironmentRpcQueryAtomFamily(runtime, {
      label: "environment-data:infinitus:machine",
      tag: WS_METHODS.infinitusCommand,
      staleTimeMs: INFINITUS_MACHINE_STALE_MS,
      refreshIntervalMs: INFINITUS_MACHINE_REFRESH_MS,
      idleTtlMs: INFINITUS_MACHINE_IDLE_TTL_MS,
    }),
    // Approve-on-Mac pairing (#710): the server's pending requests, resent
    // whole on every change (metadata and the match code only — never the
    // phone's secret or the credential). No idle grace: a request lives two
    // minutes, so a released view starts over rather than showing a stale list.
    pairing: createEnvironmentSubscriptionAtomFamily(runtime, {
      label: "environment-data:infinitus:pairing",
      idleTtlMs: INFINITUS_PAIRING_IDLE_TTL_MS,
      subscribe: (input: EnvironmentRpcInput<typeof WS_METHODS.subscribeInfinitusPairing>) =>
        subscribe(WS_METHODS.subscribeInfinitusPairing, input),
    }),
    // The decided request leaves the stream, so nothing to invalidate.
    pairingDecide: createEnvironmentRpcCommand(runtime, {
      label: "environment-data:infinitus:pairingDecide",
      tag: WS_METHODS.infinitusPairingDecide,
    }),
  };
}
