import { createInfinitusEnvironmentAtoms } from "@infinitus/client-runtime/state/infinitus";
import { createInfinitusLimitStopsAtom } from "@infinitus/client-runtime/state/infinitusLimitStops";

import { environmentCatalog } from "../connection/catalog";
import { connectionAtomRuntime } from "../connection/runtime";

/** The Infinitus snapshot stream and command per environment (#572): every
    paired Mac that runs Infinitus is one environment with the `infinitus`
    capability, and its fleet arrives through the T3 server's adapter. */
export const infinitusEnvironment = createInfinitusEnvironmentAtoms(connectionAtomRuntime);

/** Every connected environment's limit-stopped threads (#648), keyed
    `environmentId:threadId`, for the thread list's "Limited" label. */
export const infinitusLimitStopsAtom = createInfinitusLimitStopsAtom({
  catalogValueAtom: environmentCatalog.catalogValueAtom,
  limitStopsAtom: infinitusEnvironment.limitStops,
});
