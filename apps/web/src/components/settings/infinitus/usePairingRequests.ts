import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentId } from "@t3tools/contracts";
import { AsyncResult, Atom } from "effect/unstable/reactivity";

import { infinitusEnvironment } from "~/state/infinitus";

import { type PairingAccess, pairingAccessOf } from "./pairingAccess.logic";

const NO_ENVIRONMENT = Atom.make(AsyncResult.initial<never, never>(false)).pipe(
  Atom.withLabel("web-infinitus-pairing:none"),
);

/**
 * The pairing-requests stream as the card and the toast hook read it (#730):
 * the raw result rather than `useEnvironmentQuery`'s flattened view, so a
 * refused stream (`forbidden`) is told apart from a broken one. Both callers
 * share the one subscription through the atom family.
 */
export function usePairingRequests(environmentId: EnvironmentId | null): PairingAccess {
  const result = useAtomValue(
    environmentId === null
      ? NO_ENVIRONMENT
      : infinitusEnvironment.pairing({ environmentId, input: {} }),
  );
  return pairingAccessOf(result);
}
