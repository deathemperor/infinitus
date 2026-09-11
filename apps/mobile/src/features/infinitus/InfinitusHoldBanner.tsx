import { useAtomValue } from "@effect/atom-react";
import { threadHold } from "@t3tools/client-runtime/state/infinitusThreadHold";
import type {
  EnvironmentId,
  OrchestrationLatestTurn,
  OrchestrationThreadActivity,
  ThreadId,
} from "@t3tools/contracts";
import { useMemo, useState } from "react";
import { Pressable, View } from "react-native";

import { AppText as Text } from "../../components/AppText";
import { infinitusEnvironment } from "../../state/infinitus";
import { environmentServerConfigsAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import {
  holdBannerBusy,
  holdBannerText,
  holdBannerTitle,
  holdPhaseAfterPin,
  holdPhaseAfterRelease,
  pinLabel,
  runNowLabel,
  type HoldPhase,
} from "./holdBanner.logic";
import { usePinThread } from "./pinThread";

/**
 * The composer card for a thread session priority mode is holding (#742, the
 * web's banner of #616): the held row's line, "Run now" (the
 * `infinitus.releaseThread` RPC) and "Pin" (pinning releases on the server).
 * Renders nothing while the thread's rows say nothing is held. A turn paused
 * by interrupt mode (#743) gets the same card as "Paused for headroom" with
 * "Resume now"; the RPC falls through to the interrupt layer. Mounted from
 * ThreadRouteScreen through ThreadDetailScreen's `infinitusHoldBanner` slot.
 */
export function InfinitusHoldBanner(props: {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
  readonly activities: ReadonlyArray<OrchestrationThreadActivity>;
  readonly latestTurn: OrchestrationLatestTurn | null;
}) {
  const { environmentId, threadId, activities, latestTurn } = props;
  const hold = useMemo(() => threadHold({ activities, latestTurn }), [activities, latestTurn]);
  const configs = useAtomValue(environmentServerConfigsAtom);
  const supportsPinning =
    configs.get(environmentId)?.environment.capabilities.threadPinning === true;
  const release = useAtomCommand(infinitusEnvironment.releaseThread, { reportFailure: false });
  const pinThread = usePinThread();
  // Keyed by the held row, so a later hold on the same thread starts idle.
  const [answered, setAnswered] = useState<{ markerId: string; phase: HoldPhase } | null>(null);
  if (hold === null) return null;
  const phase: HoldPhase =
    answered !== null && answered.markerId === hold.markerId ? answered.phase : { kind: "idle" };
  const settle = (next: HoldPhase) => setAnswered({ markerId: hold.markerId, phase: next });
  const { description, actionable } = holdBannerText(hold.summary, phase, hold.kind);
  const runNow = runNowLabel(phase, hold.kind);
  const busy = holdBannerBusy(phase);

  return (
    <View className="gap-2.5 rounded-[20px] border border-adaptive-neutral-200-white-a6 bg-adaptive-neutral-100-900 p-4">
      <Text className="font-t3-bold text-2xs uppercase tracking-[1.1px] text-adaptive-neutral-600-400">
        {holdBannerTitle(hold.kind)}
      </Text>
      <Text
        accessibilityLiveRegion="polite"
        className="font-sans text-sm leading-normal text-adaptive-neutral-600-400"
      >
        {description}
      </Text>
      {actionable ? (
        <View className="flex-row gap-2">
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={runNow}
            disabled={busy}
            className={`items-center justify-center rounded-[14px] bg-blue-500 px-3.5 py-3 ${busy ? "opacity-60" : "active:opacity-80"}`}
            onPress={() => {
              settle({ kind: "releasing" });
              void release({ environmentId, input: { threadId } }).then((result) =>
                settle(holdPhaseAfterRelease(result)),
              );
            }}
          >
            <Text className="text-sm font-t3-extrabold text-white">{runNow}</Text>
          </Pressable>
          {supportsPinning ? (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Pin thread"
              disabled={busy}
              className={`items-center justify-center rounded-[14px] border border-adaptive-neutral-200-white-a6 px-3.5 py-3 ${busy ? "opacity-60" : "active:opacity-80"}`}
              onPress={() => {
                settle({ kind: "pinning" });
                void pinThread({ environmentId, threadId }).then((outcome) =>
                  settle(holdPhaseAfterPin(outcome)),
                );
              }}
            >
              <Text className="text-sm font-t3-extrabold text-foreground">{pinLabel(phase)}</Text>
            </Pressable>
          ) : null}
        </View>
      ) : null}
    </View>
  );
}
