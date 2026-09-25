import { useAtomValue } from "@effect/atom-react";
import { heldEntryFor } from "@infinitus/client-runtime/state/infinitusThreadHold";
import type { EnvironmentId, ThreadId } from "@infinitus/contracts";

import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { serverEnvironment } from "../../state/server";

/**
 * Whether the server holds this thread's turn start for headroom (#616,
 * #741) or has it parked on a usage limit (#270 I): the row's kind and line,
 * or null. The phone's copy of the web's `useInfinitusHeldSummary`: every
 * row on one Mac shares the one `subscribeInfinitusHolds` stream through
 * the atom family (kept mounted by `InfinitusHoldsBridge`), and an
 * environment without the Infinitus capability subscribes to nothing. The
 * capability reads through a selector so a row wakes only when it flips.
 */
export function useThreadHeldEntry(
  environmentId: EnvironmentId,
  threadId: ThreadId,
): ReturnType<typeof heldEntryFor> {
  const supported = useAtomValue(
    serverEnvironment.configValueAtom(environmentId),
    (config) => config?.environment.capabilities.infinitus === true,
  );
  const holds = useEnvironmentQuery(
    supported ? infinitusEnvironment.holds({ environmentId, input: {} }) : null,
  );
  return heldEntryFor(holds.data, threadId);
}
