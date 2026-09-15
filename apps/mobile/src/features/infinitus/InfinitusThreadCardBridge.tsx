import { useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/unstable/reactivity";
import { addActivityUpdateListener, addPushToStartTokenListener } from "expo-widgets";
import { useEffect, useMemo, useRef } from "react";
import { AppState, Platform } from "react-native";

import { loadOrCreateAgentAwarenessDeviceId } from "../../persistence/imperative";
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
import { requestConnectionWakeup } from "./connectionWakeups";
import {
  noteAgentActivityWatching,
  noteBackgroundCard,
  noteSwitchOff,
  noteTokenWithdrawn,
} from "./pushDiagnostics";
import { useForgetOnSwitchOff } from "./pushForget";
import { forgetTokensOutcome } from "./pushForget.logic";
import { tokenSender } from "./pushRegistration";
import { startThreadCardBridge } from "./threadCardBridge.controller";

/** Headless. Hands this phone's thread-card tokens to the Mac that pushes
    them (#1047): the push-to-start token as `agent-activity-start`, so the
    Mac can start upstream's `AgentActivity` card with the app closed, and
    each running card's own token as `agent-activity`, re-read on every
    foreground because the Mac may have started a card while the app was
    closed, and after a card this app starts itself (the test card). iOS
    only; nothing runs until the preferences have loaded, and nothing when
    the switch is off or no paired Mac runs Infinitus. The switch going off
    withdraws both kinds from the Mac (#702).

    Every token iOS hands over is kept and re-sent until the Mac holds it
    (#941): ActivityKit vends the push-to-start token the moment this mounts,
    which is before the environment's socket is up, so the first send failed
    with an unreachable RPC and the Mac was left with nothing to start a card
    with. A send that does not land backs off while the Mac is reachable, and
    the Mac becoming reachable — or the app coming to the foreground — sends
    again at once.

    A card iOS starts from the Mac's push-to-start while the app is in the
    background is seen through the fork's `onExpoWidgetsActivityUpdate` event
    (patched into expo-widgets, #1277): every activity start or state change
    re-reads the live cards, so the new card's own token reaches the Mac and
    the next push updates it in place instead of starting another. Without
    that event the scan ran only at mount, on a foreground and after a local
    start or end, and five pushes made five cards. The socket to the Mac is
    down in that background window — the connection layer reconnects only on
    the app becoming active — so a card started there also asks for the
    `application-active-reconnect` wakeup at once (`connectionWakeups.ts`),
    and the Settings row records how long the token took, or that the Mac
    stayed unreachable until the next foreground.

    A card's own token is withdrawn once no card is live (#1265): the scan
    is the phone's mechanism, so every re-scan that finds
    `getInstances()` empty — at mount, on a foreground, after a local start or
    end — forgets `agent-activity` at the Mac, once per empty stretch and
    never gated on what this run remembers offering (a reinstall replaces the
    card whose token the Mac still holds). Without it the Mac keeps pushing
    into an ended card and never starts the next one from the start token. A
    stale card is still listed and updatable, so its token stays. The forget
    rides the send loop: retried while the Mac is unreachable, dropped when a
    new card's token is offered, so a card that starts while the forget is in
    flight keeps its registration. */
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
  const connected = mac?.connected === true;
  const connectedRef = useRef(connected);
  const retryRef = useRef<(() => void) | null>(null);

  useForgetOnSwitchOff({
    enabled: Platform.OS === "ios" && loaded ? enabled : null,
    environmentId,
    kinds: AGENT_ACTIVITY_TOKEN_KINDS,
    run,
    onOutcome: noteSwitchOff,
  });

  useEffect(() => {
    if (Platform.OS !== "ios" || !enabled || environmentId === null) return;
    const bridge = startThreadCardBridge({
      makeSend: (isCancelled) => tokenSender({ environmentId, run, isCancelled }),
      forgetCardToken: async () =>
        (
          await forgetTokensOutcome({
            environmentId,
            kinds: ["agent-activity"],
            run,
            loadDeviceId: loadOrCreateAgentAwarenessDeviceId,
          })
        ).outcome === "withdrawn",
      getInstances: () => AgentActivity.getInstances(),
      addPushToStartTokenListener,
      addAppStateListener: (listener) => AppState.addEventListener("change", listener),
      addActivityUpdateListener,
      subscribeLocalChanges: (listener) =>
        appAtomRegistry.subscribe(localLiveActivityStartsAtom, listener),
      isConnected: () => connectedRef.current,
      appState: () => AppState.currentState,
      requestReconnect: () => requestConnectionWakeup("application-active-reconnect"),
      now: () => new Date(),
      notes: {
        watching: noteAgentActivityWatching,
        withdrawn: noteTokenWithdrawn,
        backgroundCard: noteBackgroundCard,
      },
    });
    retryRef.current = bridge.retry;
    return () => {
      retryRef.current = null;
      bridge.stop();
    };
  }, [enabled, environmentId, run]);

  /** The Mac reaching this phone is what the first send was missing; it is not
      an effect dependency, so a connection flap never re-attaches the
      listeners — it only asks the bridge to send what it holds. */
  useEffect(() => {
    connectedRef.current = connected;
    if (connected) retryRef.current?.();
  }, [connected]);

  return null;
}
