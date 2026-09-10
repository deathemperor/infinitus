import { WS_METHODS } from "@t3tools/contracts";
import type {
  InfinitusAccount,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import type { Atom } from "effect/unstable/reactivity";

import { createEnvironmentRpcCommand, createEnvironmentSubscriptionAtomFamily } from "./runtime.ts";
import type { EnvironmentRegistry } from "../connection/registry.ts";
import { subscribe, type EnvironmentRpcInput } from "../rpc/client.ts";

// The server holds one snapshot per environment and only polls the control
// socket while a client watches, so a released view keeps its stream briefly
// rather than paying for a fresh poll when the user comes back.
const INFINITUS_SNAPSHOT_IDLE_TTL_MS = 60_000;

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
  };
}
