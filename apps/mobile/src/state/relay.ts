import { createRelayEnvironmentDiscoveryAtoms } from "@infinitus/client-runtime/state/relay";

import { connectionAtomRuntime } from "../connection/runtime";

export const relayEnvironmentDiscovery =
  createRelayEnvironmentDiscoveryAtoms(connectionAtomRuntime);
