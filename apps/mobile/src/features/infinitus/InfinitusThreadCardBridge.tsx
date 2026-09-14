import { useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/unstable/reactivity";
import { addPushToStartTokenListener } from "expo-widgets";
import { useEffect, useMemo, useRef } from "react";
import { AppState, Platform } from "react-native";

import { appAtomRegistry } from "../../state/atom-registry";
import { infinitusEnvironment } from "../../state/infinitus";
import { mobilePreferencesAtom } from "../../state/preferences";
import { environmentPresentations } from "../../state/presentation";
import { environmentServerConfigsAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import AgentActivity from "../../widgets/AgentActivity";
import { infinitusMacs } from "../accounts/accountsRoute.logic";
import {
  AGENT_ACTIVITY_TOKEN_KINDS,
  type LiveActivityTokenKind,
  pusherMac,
} from "./liveActivity.logic";
import { localLiveActivityStartsAtom } from "./liveActivityStarts";
import { noteAgentActivityWatching } from "./pushDiagnostics";
import { useForgetOnSwitchOff } from "./pushForget";
import { tokenSender } from "./pushRegistration";
import { nextRetry, NO_RETRY } from "./pushRetry.logic";

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
    again at once. */
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
  });

  useEffect(() => {
    if (Platform.OS !== "ios" || !enabled || environmentId === null) return;
    let cancelled = false;
    const watched = new Set<string>();
    const subscriptions: Array<{ remove(): void }> = [];
    const send = tokenSender({ environmentId, run, isCancelled: () => cancelled });
    /** The newest token iOS has handed over per kind, sent until it lands. */
    const latest = new Map<LiveActivityTokenKind, string>();
    let schedule = NO_RETRY;
    let timer: ReturnType<typeof setTimeout> | null = null;
    let sending = false;
    let again = false;

    const clearTimer = () => {
      if (timer !== null) clearTimeout(timer);
      timer = null;
    };

    /** One round over every held token. Rounds never overlap: a second one
        asked for mid-flight waits, since a throttled repeat answers "on file"
        for a send whose failure has not been recorded yet, and would read as
        a landing that cancels the retry the failing round is about to set. */
    const flush = async (): Promise<void> => {
      if (sending) {
        again = true;
        return;
      }
      sending = true;
      clearTimer();
      try {
        const outcomes = await Promise.all([...latest].map(([kind, token]) => send(kind, token)));
        if (cancelled) return;
        schedule = nextRetry({
          attempt: schedule.attempt,
          landed: outcomes.every(Boolean),
          connected: connectedRef.current,
        });
        if (schedule.delayMs !== null) timer = setTimeout(() => void flush(), schedule.delayMs);
      } finally {
        sending = false;
      }
      if (again && !cancelled) {
        again = false;
        await flush();
      }
    };

    /** A token from iOS: a new one is a fresh chance, so the backoff resets. */
    const offer = (kind: LiveActivityTokenKind, token: string) => {
      if (cancelled || latest.get(kind) === token) return;
      latest.set(kind, token);
      schedule = NO_RETRY;
      void flush();
    };

    const attach = () => {
      for (const activity of AgentActivity.getInstances()) {
        const id = activity.getId();
        if (watched.has(id)) continue;
        watched.add(id);
        subscriptions.push(
          activity.addPushTokenListener((event) => offer("agent-activity", event.pushToken)),
        );
        void activity.getPushToken().then((token) => {
          if (token) offer("agent-activity", token);
        });
      }
    };

    subscriptions.push(
      addPushToStartTokenListener((event) =>
        offer("agent-activity-start", event.activityPushToStartToken),
      ),
    );
    attach();
    noteAgentActivityWatching(new Date());
    retryRef.current = () => {
      schedule = NO_RETRY;
      void flush();
    };
    const appState = AppState.addEventListener("change", (state) => {
      if (state !== "active") return;
      attach();
      retryRef.current?.();
    });
    const localStarts = appAtomRegistry.subscribe(localLiveActivityStartsAtom, attach);
    return () => {
      cancelled = true;
      retryRef.current = null;
      clearTimer();
      noteAgentActivityWatching(null);
      appState.remove();
      localStarts();
      for (const subscription of subscriptions) subscription.remove();
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
