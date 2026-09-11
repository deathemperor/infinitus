import { useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/unstable/reactivity";
import * as Notifications from "expo-notifications";
import { useEffect, useMemo } from "react";
import { AppState, Linking, Platform } from "react-native";

import { infinitusEnvironment } from "../../state/infinitus";
import { mobilePreferencesAtom } from "../../state/preferences";
import { environmentPresentations } from "../../state/presentation";
import { environmentServerConfigsAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import { infinitusMacs } from "../accounts/accountsRoute.logic";
import { supportsAgentAwarenessPush } from "../agent-awareness/capabilities";
import { deviceTokenOf, isMacAlertResponse } from "./alertPush.logic";
import { INFINITUS_ALARM_DEEP_LINK } from "./InfinitusAlarmsBridge";
import { pusherMac } from "./liveActivity.logic";
import { useForgetOnSwitchOff } from "./pushForget";
import { tokenSender } from "./pushRegistration";

/** Headless. Registers this phone's plain notification token with the Mac
    that drives its cards as the `alert` kind (#702), so the Mac's limit /
    waiting / AWS-login alerts reach the phone as banners; a tap opens
    Settings › Accounts. Re-sent when APNs rotates the token and on every
    foreground (throttled). iOS only, off until the toggle is on, and nothing
    is sent until notifications are granted — the switch asks. The switch
    going off withdraws the registration from the Mac (#702). */
const ALERT_KINDS = ["alert"] as const;

export function InfinitusAlertPushBridge() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const loaded = AsyncResult.isSuccess(preferences);
  const enabled = loaded && preferences.value.infinitusPushAlertsEnabled === true;
  const preferred = loaded ? preferences.value.infinitusLiveActivityMac : undefined;
  const mac = useMemo(
    () => pusherMac(preferred, infinitusMacs(configs, presentations)),
    [configs, preferred, presentations],
  );
  const environmentId = mac?.environmentId ?? null;

  useForgetOnSwitchOff({
    enabled: Platform.OS === "ios" && loaded ? enabled : null,
    environmentId,
    kinds: ALERT_KINDS,
    run,
  });

  useEffect(() => {
    if (Platform.OS !== "ios") return;
    const subscription = Notifications.addNotificationResponseReceivedListener((response) => {
      if (isMacAlertResponse(response)) void Linking.openURL(INFINITUS_ALARM_DEEP_LINK);
    });
    return () => subscription.remove();
  }, []);

  useEffect(() => {
    if (Platform.OS !== "ios" || !supportsAgentAwarenessPush()) return;
    if (!enabled || environmentId === null) return;
    let cancelled = false;
    const send = tokenSender({ environmentId, run, isCancelled: () => cancelled });

    const file = async (read: () => Promise<string | null>) => {
      try {
        if (!(await Notifications.getPermissionsAsync()).granted) return;
        const token = await read();
        if (token !== null && !cancelled) await send("alert", token);
      } catch {
        // No token yet (simulator, or APNs unreachable): the next foreground retries.
      }
    };
    const current = () =>
      Notifications.getDevicePushTokenAsync().then((token) => deviceTokenOf(token, Platform.OS));

    const rotation = Notifications.addPushTokenListener((token) => {
      void file(() => Promise.resolve(deviceTokenOf(token, Platform.OS)));
    });
    void file(current);
    const appState = AppState.addEventListener("change", (state) => {
      if (state === "active") void file(current);
    });
    return () => {
      cancelled = true;
      rotation.remove();
      appState.remove();
    };
  }, [enabled, environmentId, run]);

  return null;
}
