import type { EnvironmentId, ThreadId } from "@t3tools/contracts";

import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { heldEntryFor } from "./infinitusHeld.logic";

/**
 * Whether the server holds this thread's turn start for headroom (#616,
 * #741) or has it parked on a usage limit (#270 I): the row's kind and line,
 * or null. Every row on one environment shares the one
 * `subscribeInfinitusHolds` stream through the atom family; an environment
 * without the Infinitus capability subscribes to nothing.
 */
export function useInfinitusHeldSummary(
  environmentId: EnvironmentId,
  threadId: ThreadId,
  supported: boolean,
): ReturnType<typeof heldEntryFor> {
  const holds = useEnvironmentQuery(
    supported ? infinitusEnvironment.holds({ environmentId, input: {} }) : null,
  );
  return heldEntryFor(holds.data, threadId);
}
