import { createInfinitusEnvironmentAtoms } from "@t3tools/client-runtime/state/infinitus";

import { connectionAtomRuntime } from "../connection/runtime";

export const infinitusEnvironment = createInfinitusEnvironmentAtoms(connectionAtomRuntime);
