import { useAtomValue } from "@effect/atom-react";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { AsyncResult } from "effect/unstable/reactivity";
import * as Notifications from "expo-notifications";
import { useEffect, useMemo, useRef } from "react";
import { Linking, Platform } from "react-native";

import { infinitusEnvironment } from "../../state/infinitus";
import { mobilePreferencesAtom } from "../../state/preferences";
import { environmentPresentations } from "../../state/presentation";
import { useEnvironmentQuery } from "../../state/query";
import { environmentServerConfigsAtom } from "../../state/server";
import { type InfinitusMac, infinitusMacs } from "../accounts/accountsRoute.logic";
import { type FleetAlarm, isInfinitusAlarmId, planAlarms } from "./alarms.logic";

export const INFINITUS_ALARM_DEEP_LINK = "t3code://settings/accounts";

/** Headless. Re-plans the phone's reset and swap alarms from every paired
    Mac's snapshot (#572 task 5) and schedules them as local notifications;
    a tap opens Settings › Accounts. Off until preferences load, when the
    toggle is off, or when notifications are not granted — the switch in
    Settings › Infinitus asks for the permission. */
export function InfinitusAlarmsBridge() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const macs = useMemo(() => infinitusMacs(configs, presentations), [configs, presentations]);
  const enabled =
    AsyncResult.isSuccess(preferences) && preferences.value.infinitusAlarmsEnabled === true;

  useEffect(() => {
    if (Platform.OS === "web") return;
    const subscription = Notifications.addNotificationResponseReceivedListener((response) => {
      const id = response.notification.request.identifier;
      if (isInfinitusAlarmId(id)) void Linking.openURL(INFINITUS_ALARM_DEEP_LINK);
    });
    return () => subscription.remove();
  }, []);

  useEffect(() => {
    if (enabled) return;
    void cancelInfinitusAlarms();
  }, [enabled]);

  if (!enabled) return null;
  return (
    <>
      {macs.map((mac) => (
        <MacAlarms key={mac.environmentId} mac={mac} />
      ))}
    </>
  );
}

function MacAlarms(props: { readonly mac: InfinitusMac }) {
  const view = useEnvironmentQuery(
    infinitusEnvironment.snapshot({ environmentId: props.mac.environmentId, input: {} }),
  );
  const previous = useRef<InfinitusSnapshot | null>(null);
  const snapshot = view.data;
  useEffect(() => {
    if (snapshot === null) return;
    const alarms = planAlarms(snapshot, previous.current, Date.now());
    previous.current = snapshot;
    void scheduleInfinitusAlarms(props.mac.environmentId, alarms);
  }, [props.mac.environmentId, snapshot]);
  return null;
}

/** Replaces this Mac's alarms with the plan: ids are `infinitus-<kind>-…`
    prefixed with the environment id, so one Mac's re-plan never touches
    another's, and T3's own notifications are never cancelled. */
async function scheduleInfinitusAlarms(environmentId: string, alarms: ReadonlyArray<FleetAlarm>) {
  try {
    const granted = (await Notifications.getPermissionsAsync()).granted;
    if (!granted) return;
    const prefix = `infinitus-${environmentId}-`;
    const scheduled = await Notifications.getAllScheduledNotificationsAsync();
    const wanted = new Set(alarms.map((alarm) => prefix + alarm.id));
    for (const request of scheduled) {
      if (request.identifier.startsWith(prefix) && !wanted.has(request.identifier)) {
        await Notifications.cancelScheduledNotificationAsync(request.identifier);
      }
    }
    const existing = new Set(scheduled.map((request) => request.identifier));
    for (const alarm of alarms) {
      const identifier = prefix + alarm.id;
      if (alarm.fireAt !== null && existing.has(identifier)) continue;
      await Notifications.scheduleNotificationAsync({
        identifier,
        content: { title: alarm.title, body: alarm.body, data: { infinitus: "accounts" } },
        trigger:
          alarm.fireAt === null
            ? null
            : {
                type: Notifications.SchedulableTriggerInputTypes.DATE,
                date: new Date(alarm.fireAt),
              },
      });
    }
  } catch (error) {
    console.warn("[infinitus] alarm scheduling failed", error);
  }
}

async function cancelInfinitusAlarms() {
  try {
    const scheduled = await Notifications.getAllScheduledNotificationsAsync();
    for (const request of scheduled) {
      if (request.identifier.startsWith("infinitus-")) {
        await Notifications.cancelScheduledNotificationAsync(request.identifier);
      }
    }
  } catch {
    // Nothing scheduled, or notifications unavailable: nothing to cancel.
  }
}
