import { useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/unstable/reactivity";
import { addPushToStartTokenListener, type LiveActivityFactory } from "expo-widgets";
import { useEffect, useMemo } from "react";
import { AppState, Platform } from "react-native";

import { infinitusEnvironment } from "../../state/infinitus";
import { mobilePreferencesAtom } from "../../state/preferences";
import { environmentPresentations } from "../../state/presentation";
import { environmentServerConfigsAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import InfinitusRevival from "../../widgets/InfinitusRevival";
import InfinitusWorking from "../../widgets/InfinitusWorking";
import { infinitusMacs } from "../accounts/accountsRoute.logic";
import {
  LIVE_ACTIVITY_TOKEN_KINDS,
  type LiveActivityTokenKind,
  pusherMac,
} from "./liveActivity.logic";
import { useForgetOnSwitchOff } from "./pushForget";
import { tokenSender } from "./pushRegistration";

const FACTORIES: ReadonlyArray<readonly [LiveActivityFactory<object>, LiveActivityTokenKind]> = [
  [InfinitusWorking, "working"],
  [InfinitusRevival, "revival"],
];

/** Headless. Hands this phone's Live Activity tokens to the Mac that drives
    its cards (#572 task 4): the push-to-start token under both start kinds,
    and each running card's update token, re-read on every foreground because
    a Mac may have started a card while the app was closed. iOS only; nothing
    runs until the preferences have loaded, and nothing when the toggle is off
    or no paired Mac runs Infinitus. The toggle going off withdraws the four
    registrations from the Mac (#702). */
export function InfinitusLiveActivityBridge() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const loaded = AsyncResult.isSuccess(preferences);
  const enabled = loaded && preferences.value.infinitusLiveActivityEnabled !== false;
  const preferred = loaded ? preferences.value.infinitusLiveActivityMac : undefined;
  const mac = useMemo(
    () => pusherMac(preferred, infinitusMacs(configs, presentations)),
    [configs, preferred, presentations],
  );
  const environmentId = mac?.environmentId ?? null;

  useForgetOnSwitchOff({
    enabled: Platform.OS === "ios" && loaded ? enabled : null,
    environmentId,
    kinds: LIVE_ACTIVITY_TOKEN_KINDS,
    run,
  });

  useEffect(() => {
    if (Platform.OS !== "ios" || !enabled || environmentId === null) return;
    let cancelled = false;
    const watched = new Set<string>();
    const subscriptions: Array<{ remove(): void }> = [];
    const send = tokenSender({ environmentId, run, isCancelled: () => cancelled });

    const attach = () => {
      for (const [factory, kind] of FACTORIES) {
        for (const activity of factory.getInstances()) {
          const id = activity.getId();
          if (watched.has(id)) continue;
          watched.add(id);
          subscriptions.push(
            activity.addPushTokenListener((event) => void send(kind, event.pushToken)),
          );
          void activity.getPushToken().then((token) => {
            if (token && !cancelled) void send(kind, token);
          });
        }
      }
    };

    subscriptions.push(
      addPushToStartTokenListener((event) => {
        void send("working-start", event.activityPushToStartToken);
        void send("revival-start", event.activityPushToStartToken);
      }),
    );
    attach();
    const appState = AppState.addEventListener("change", (state) => {
      if (state === "active") attach();
    });
    return () => {
      cancelled = true;
      appState.remove();
      for (const subscription of subscriptions) subscription.remove();
    };
  }, [enabled, environmentId, run]);

  return null;
}
