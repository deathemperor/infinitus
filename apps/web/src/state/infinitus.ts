import { createInfinitusEnvironmentAtoms } from "@infinitus/client-runtime/state/infinitus";
import { createInfinitusLimitStopsAtom } from "@infinitus/client-runtime/state/infinitusLimitStops";

import { environmentCatalog } from "../connection/catalog";
import { connectionAtomRuntime } from "../connection/runtime";

export const infinitusEnvironment = createInfinitusEnvironmentAtoms(connectionAtomRuntime);

/** Every connected environment's limit-stopped threads (#648), keyed
    `environmentId:threadId`, for the sidebar's "Limited" pill. */
export const infinitusLimitStopsAtom = createInfinitusLimitStopsAtom({
  catalogValueAtom: environmentCatalog.catalogValueAtom,
  limitStopsAtom: infinitusEnvironment.limitStops,
});
