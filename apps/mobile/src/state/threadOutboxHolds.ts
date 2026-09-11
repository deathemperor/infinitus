import type { EnvironmentId, ServerConfig } from "@t3tools/contracts";
import type { InfinitusHeldThread } from "@t3tools/contracts/infinitus";
import * as Option from "effect/Option";
import { AsyncResult } from "effect/unstable/reactivity";

import { appAtomRegistry } from "./atom-registry";
import { infinitusEnvironment } from "./infinitus";

/**
 * The threads an Infinitus environment currently holds (#741), read straight
 * from the holds atom for the outbox drain (#807) — the same read the web
 * sidebar's next-attention key does. Null for an environment without the
 * `infinitus` capability and until the list's first delivery, so the first
 * pass after the app opens may not yet see a hold.
 */
export function readHeldThreads(
  environmentId: EnvironmentId,
  serverConfigs: ReadonlyMap<EnvironmentId, ServerConfig>,
): ReadonlyArray<InfinitusHeldThread> | null {
  if (serverConfigs.get(environmentId)?.environment.capabilities.infinitus !== true) return null;
  return Option.getOrNull(
    AsyncResult.value(
      appAtomRegistry.get(infinitusEnvironment.holds({ environmentId, input: {} })),
    ),
  );
}
