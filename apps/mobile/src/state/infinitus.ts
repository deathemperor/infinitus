import { createInfinitusEnvironmentAtoms } from "@t3tools/client-runtime/state/infinitus";

import { connectionAtomRuntime } from "../connection/runtime";

/** The Infinitus snapshot stream and command per environment (#572): every
    paired Mac that runs Infinitus is one environment with the `infinitus`
    capability, and its fleet arrives through the T3 server's adapter. */
export const infinitusEnvironment = createInfinitusEnvironmentAtoms(connectionAtomRuntime);
