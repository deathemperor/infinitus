import { useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/unstable/reactivity";
import { addPushToStartTokenListener } from "expo-widgets";
import { useEffect, useMemo } from "react";
import { AppState, Platform } from "react-native";

import { appAtomRegistry } from "../../state/atom-registry";
import { infinitusEnvironment } from "../../state/infinitus";
import { mobilePreferencesAtom } from "../../state/preferences";
import { environmentPresentations } from "../../state/presentation";
import { environmentServerConfigsAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import AgentActivity from "../../widgets/AgentActivity";
import { infinitusMacs } from "../accounts/accountsRoute.logic";
import { AGENT_ACTIVITY_TOKEN_KINDS, pusherMac } from "./liveActivity.logic";
import { localLiveActivityStartsAtom } from "./liveActivityStarts";
import { useForgetOnSwitchOff } from "./pushForget";
import { tokenSender } from "./pushRegistration";

/** Headless. Hands this phone's thread-card tokens to the Mac that pushes
    them (#1047): the push-to-start token as `agent-activity-start`, so the
    Mac can start upstream's `AgentActivity` card with the app closed, and
    each running card's own token as `agent-activity`, re-read on every
    foreground because the Mac may have started a card while the app was
    closed, and after a card this app starts itself (the test card). iOS
    only; nothing runs until the preferences have loaded, and nothing when
    the switch is off or no paired Mac runs Infinitus. The switch going off
    withdraws both kinds from the Mac (#702). */
export function InfinitusThreadCardBridge() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const loaded = AsyncResult.isSuccess(preferences);
  const enabled = loaded && preferences.value.infinitusThreadCardEnabled !== false;
  const preferred = loaded ? preferences.value.infinitusLiveActivityMac : undefined;
  const mac = useMemo(
    () => pusherMac(preferred, infinitusMacs(configs, presentations)),
    [configs, preferred, presentations],
  );
  const environmentId = mac?.environmentId ?? null;

  useForgetOnSwitchOff({
    enabled: Platform.OS === "ios" && loaded ? enabled : null,
    environmentId,
    kinds: AGENT_ACTIVITY_TOKEN_KINDS,
    run,
  });

  useEffect(() => {
    if (Platform.OS !== "ios" || !enabled || environmentId === null) return;
    let cancelled = false;
    const watched = new Set<string>();
    const subscriptions: Array<{ remove(): void }> = [];
    const send = tokenSender({ environmentId, run, isCancelled: () => cancelled });

    const attach = () => {
      for (const activity of AgentActivity.getInstances()) {
        const id = activity.getId();
        if (watched.has(id)) continue;
        watched.add(id);
        subscriptions.push(
          activity.addPushTokenListener((event) => void send("agent-activity", event.pushToken)),
        );
        void activity.getPushToken().then((token) => {
          if (token && !cancelled) void send("agent-activity", token);
        });
      }
    };

    subscriptions.push(
      addPushToStartTokenListener(
        (event) => void send("agent-activity-start", event.activityPushToStartToken),
      ),
    );
    attach();
    const appState = AppState.addEventListener("change", (state) => {
      if (state === "active") attach();
    });
    const localStarts = appAtomRegistry.subscribe(localLiveActivityStartsAtom, attach);
    return () => {
      cancelled = true;
      appState.remove();
      localStarts();
      for (const subscription of subscriptions) subscription.remove();
    };
  }, [enabled, environmentId, run]);

  return null;
}
