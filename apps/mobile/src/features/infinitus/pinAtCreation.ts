import type { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { useCallback } from "react";

import { appAtomRegistry } from "../../state/atom-registry";
import { mobilePreferencesAtom } from "../../state/preferences";
import { pinAtCreationEnabled } from "./pinAtCreation.logic";
import { usePinThread, type PinOutcome } from "./pinThread";

/**
 * Pins a thread the outbox drain has just created, when this phone's "Pin on
 * create" is on (#742). Read at drain time — a task queued offline drains
 * with the preference as it stands then. The pin lands through the ordinary
 * `thread.pin` path, which releases a first start the hold layer already
 * kept; a failure is silent, the held banner still offers Pin by hand.
 */
export function usePinAtCreation(): (target: {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
}) => Promise<PinOutcome | "skipped"> {
  const pinThread = usePinThread();
  return useCallback(
    async (target) =>
      pinAtCreationEnabled(appAtomRegistry.get(mobilePreferencesAtom))
        ? pinThread(target)
        : "skipped",
    [pinThread],
  );
}
