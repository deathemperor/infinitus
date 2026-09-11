import type { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { useCallback } from "react";

import { appAtomRegistry } from "../../state/atom-registry";
import { environmentServerConfigsAtom } from "../../state/server";
import { environmentThreadShells, threadEnvironment } from "../../state/threads";
import { useAtomCommand } from "../../state/use-atom-command";
import { newPinOrderKey, pinningSupport } from "./pinThread.logic";

export type PinOutcome = "pinned" | "unsupported" | "failed";

/** Pins one thread the way the thread list does (capability gate, top-of-run
    order key on servers that reorder), without its alerts: the caller says
    what happened. Shared by the held banner (#742) and pin-at-creation. */
export function usePinThread(): (target: {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
}) => Promise<PinOutcome> {
  const pin = useAtomCommand(threadEnvironment.pin, { reportFailure: false });
  return useCallback(
    async (target) => {
      const support = pinningSupport(
        appAtomRegistry.get(environmentServerConfigsAtom).get(target.environmentId)?.environment
          .capabilities,
      );
      if (!support.pin) return "unsupported";
      const orderKey = support.reorder
        ? newPinOrderKey(appAtomRegistry.get(environmentThreadShells.threadShellsAtom))
        : undefined;
      const result = await pin({
        environmentId: target.environmentId,
        input: { threadId: target.threadId, ...(orderKey !== undefined ? { orderKey } : {}) },
      });
      return result._tag === "Failure" ? "failed" : "pinned";
    },
    [pin],
  );
}
