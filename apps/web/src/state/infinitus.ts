import { createInfinitusEnvironmentAtoms } from "@infinitus/client-runtime/state/infinitus";

import { connectionAtomRuntime } from "../connection/runtime";

export const infinitusEnvironment = createInfinitusEnvironmentAtoms(connectionAtomRuntime);
