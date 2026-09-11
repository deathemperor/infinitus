import { threadHold } from "@t3tools/client-runtime/state/infinitusThreadHold";
import type { ScopedThreadRef } from "@t3tools/contracts";
import { CirclePauseIcon } from "lucide-react";
import { useMemo, useState } from "react";

import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";
import type { Thread } from "~/types";

import { Button } from "../ui/button";
import type { ComposerBannerStackItem } from "./ComposerBannerStack";
import {
  holdBannerText,
  holdPhaseAfterRelease,
  runNowLabel,
  type HoldPhase,
} from "./infinitusHoldBanner.logic";

/**
 * The composer banner for a thread session priority mode is holding (#616):
 * the held row's line, "Run now" (the `infinitus.releaseThread` RPC) and
 * "Pin" (pinning releases on the server). Null when the thread's rows say
 * nothing is held. Mounted from ChatView beside the snoozed/settled banners.
 */
export function useInfinitusHoldBanner(input: {
  readonly thread: Thread | null;
  readonly threadRef: ScopedThreadRef | null;
  readonly supportsPinning: boolean;
  readonly pinThread: (target: ScopedThreadRef) => Promise<{ readonly _tag: string }>;
}): ComposerBannerStackItem | null {
  const { thread, threadRef, supportsPinning, pinThread } = input;
  const activities = thread?.activities;
  const latestTurn = thread?.latestTurn ?? null;
  const hold = useMemo(
    () => (activities === undefined ? null : threadHold({ activities, latestTurn })),
    [activities, latestTurn],
  );
  const release = useAtomCommand(infinitusEnvironment.releaseThread, { reportFailure: false });
  // Keyed by the held row, so a later hold on the same thread starts idle.
  const [answered, setAnswered] = useState<{ markerId: string; phase: HoldPhase } | null>(null);
  const phase: HoldPhase =
    answered !== null && hold !== null && answered.markerId === hold.markerId
      ? answered.phase
      : { kind: "idle" };

  return useMemo<ComposerBannerStackItem | null>(() => {
    if (hold === null || threadRef === null) return null;
    const { description, actionable } = holdBannerText(hold.summary, phase);
    const busy =
      phase.kind === "releasing" || phase.kind === "released" || phase.kind === "pinning";
    const settle = (next: HoldPhase) => setAnswered({ markerId: hold.markerId, phase: next });
    return {
      id: `infinitus-held:${threadRef.threadId}:${hold.markerId}`,
      variant: "info",
      icon: <CirclePauseIcon />,
      title: "Waiting for headroom",
      description,
      actions: actionable ? (
        <>
          <Button
            size="xs"
            variant="ghost"
            disabled={busy}
            onClick={() => {
              settle({ kind: "releasing" });
              void release({
                environmentId: threadRef.environmentId,
                input: { threadId: threadRef.threadId },
              }).then((result) => settle(holdPhaseAfterRelease(result)));
            }}
          >
            {runNowLabel(phase)}
          </Button>
          {supportsPinning ? (
            <Button
              size="xs"
              variant="ghost"
              disabled={busy}
              onClick={() => {
                settle({ kind: "pinning" });
                void pinThread(threadRef).then((result) =>
                  settle(
                    result._tag === "Failure"
                      ? { kind: "failed", message: "the thread could not be pinned" }
                      : { kind: "idle" },
                  ),
                );
              }}
            >
              {phase.kind === "pinning" ? "Pinning..." : "Pin"}
            </Button>
          ) : null}
        </>
      ) : undefined,
    };
  }, [hold, phase, pinThread, release, supportsPinning, threadRef]);
}
