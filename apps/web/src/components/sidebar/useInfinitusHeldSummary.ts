import type { EnvironmentId, ThreadId } from "@t3tools/contracts";

import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { heldSummaryFor } from "./infinitusHeld.logic";

/**
 * Whether the server holds this thread's turn start for headroom (#616,
 * #741): the held row's line, or null. Every row on one environment shares
 * the one `subscribeInfinitusHolds` stream through the atom family; an
 * environment without the Infinitus capability subscribes to nothing.
 */
export function useInfinitusHeldSummary(
  environmentId: EnvironmentId,
  threadId: ThreadId,
  supported: boolean,
): string | null {
  const holds = useEnvironmentQuery(
    supported ? infinitusEnvironment.holds({ environmentId, input: {} }) : null,
  );
  return heldSummaryFor(holds.data, threadId);
}
