import { WS_METHODS } from "@t3tools/contracts";
import type { Atom } from "effect/unstable/reactivity";

import { createEnvironmentRpcCommand, createEnvironmentSubscriptionAtomFamily } from "./runtime.ts";
import type { EnvironmentRegistry } from "../connection/registry.ts";
import { subscribe, type EnvironmentRpcInput } from "../rpc/client.ts";

/** A project's list stays briefly after its last viewer leaves, so opening
    the popover again on the same thread shows the list at once. */
const CAPTURES_IDLE_TTL_MS = 60_000;

/**
 * Captures (#433) per environment: `list` is a project's whole list as the
 * server streams it (keyed by `{environmentId, input: {projectId}}`), `apply`
 * sends one change; the new list rides the subscription, so nothing here
 * holds optimistic state.
 */
export function createCaptureAtoms<R, E>(runtime: Atom.AtomRuntime<EnvironmentRegistry | R, E>) {
  return {
    list: createEnvironmentSubscriptionAtomFamily(runtime, {
      label: "environment-data:captures:list",
      idleTtlMs: CAPTURES_IDLE_TTL_MS,
      subscribe: (input: EnvironmentRpcInput<typeof WS_METHODS.subscribeCaptures>) =>
        subscribe(WS_METHODS.subscribeCaptures, input),
    }),
    apply: createEnvironmentRpcCommand(runtime, {
      label: "environment-data:captures:apply",
      tag: WS_METHODS.capturesApply,
    }),
  };
}
