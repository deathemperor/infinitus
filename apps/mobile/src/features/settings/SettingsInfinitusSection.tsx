import { useAtomSet, useAtomValue } from "@effect/atom-react";
import type { MenuAction } from "@react-native-menu/menu";
import * as Effect from "effect/Effect";
import { AsyncResult } from "effect/unstable/reactivity";
import { useCallback, useMemo, useState } from "react";
import { Alert, Platform } from "react-native";

import { ControlPillMenu } from "../../components/ControlPill";
import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../state/preferences";
import { environmentPresentations } from "../../state/presentation";
import { environmentServerConfigsAtom } from "../../state/server";
import { infinitusMacs } from "../accounts/accountsRoute.logic";
import { requestAgentNotificationPermission } from "../agent-awareness/notificationPermissions";
import { pusherMac } from "../infinitus/liveActivity.logic";
import { noteLocalLiveActivityStart } from "../infinitus/liveActivityStarts";
import { testCardLabel, toggleTestCard } from "../infinitus/testCard.logic";
import InfinitusWorking from "../../widgets/InfinitusWorking";
import { SettingsRow } from "./components/SettingsRow";
import { SettingsSection } from "./components/SettingsSection";
import { SettingsSwitchRow } from "./components/SettingsSwitchRow";

/** The working cards live on this phone right now, none off iOS or when
    the widgets module is not there. */
function countLiveCards(): number {
  if (Platform.OS !== "ios") return 0;
  try {
    return InfinitusWorking.getInstances().length;
  } catch {
    return 0;
  }
}

/** Settings › Infinitus (fork, #572): the Live Activity toggle, the Mac
    alerts toggle (#702) and the reset / swap alarms toggle (both ask for the
    notification permission) and, with several Macs, which one drives the
    cards and sends the alerts. Absent until a paired Mac runs
    Infinitus, so plain T3 users never see it. */
export function SettingsInfinitusSection() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const macs = useMemo(() => infinitusMacs(configs, presentations), [configs, presentations]);
  const loaded = AsyncResult.isSuccess(preferences);
  const enabled = loaded && preferences.value.infinitusLiveActivityEnabled !== false;
  const alarmsEnabled = loaded && preferences.value.infinitusAlarmsEnabled === true;
  const pushAlertsEnabled = loaded && preferences.value.infinitusPushAlertsEnabled === true;
  const pusher = pusherMac(loaded ? preferences.value.infinitusLiveActivityMac : undefined, macs);
  // The test-card row (#845): how many working cards are live, re-read
  // after every press; the count is what the row offers to end.
  const [liveCards, setLiveCards] = useState(countLiveCards);
  const pressTestCard = useCallback(async () => {
    const outcome = await toggleTestCard(InfinitusWorking);
    setLiveCards(countLiveCards());
    // The bridge re-scans and files the new card's update token with the Mac.
    if (outcome.action === "started") noteLocalLiveActivityStart();
    if (outcome.action === "failed") {
      Alert.alert("No card", `iOS refused the Live Activity: ${outcome.message}`);
    }
  }, []);
  const macActions = useMemo<MenuAction[]>(
    () =>
      macs.map((mac) => ({
        id: mac.environmentId,
        title: mac.label,
        state: mac.environmentId === pusher?.environmentId ? "on" : "off",
      })),
    [macs, pusher?.environmentId],
  );

  if (macs.length === 0) return null;
  return (
    <SettingsSection title="Infinitus">
      <SettingsRow icon="person.2" label="Accounts" target="SettingsAccounts" />
      <SettingsSwitchRow
        icon="bolt.badge.clock"
        label="Live Activity from Mac"
        subtitle={
          Platform.OS === "ios"
            ? "The Mac keeps the lock-screen card moving over push, app closed."
            : "Live Activities are an iOS feature."
        }
        disabled={Platform.OS !== "ios" || !loaded}
        value={enabled}
        onValueChange={(value) => savePreferences({ infinitusLiveActivityEnabled: value })}
      />
      {Platform.OS === "ios" ? (
        <SettingsRow
          icon="rectangle.badge.checkmark"
          label={testCardLabel(liveCards)}
          value={liveCards === 0 ? "No push involved" : `${liveCards} live`}
          disabled={!enabled}
          onPress={() => void pressTestCard()}
        />
      ) : null}
      <SettingsSwitchRow
        icon="bell.badge"
        label="Alerts from Mac"
        subtitle={
          Platform.OS === "ios"
            ? "The Mac's limit, waiting and sign-in alerts arrive as banners."
            : "Mac alerts reach iPhones only."
        }
        disabled={Platform.OS !== "ios" || !loaded}
        value={pushAlertsEnabled}
        onValueChange={(value) => {
          savePreferences({ infinitusPushAlertsEnabled: value });
          if (value)
            void Effect.runPromise(requestAgentNotificationPermission).catch(() => undefined);
        }}
      />
      <SettingsSwitchRow
        icon="alarm"
        label="Reset alarms"
        subtitle="A banner before an exhausted account's limit lifts, and when the fleet swaps."
        disabled={!loaded}
        value={alarmsEnabled}
        onValueChange={(value) => {
          savePreferences({ infinitusAlarmsEnabled: value });
          if (value)
            void Effect.runPromise(requestAgentNotificationPermission).catch(() => undefined);
        }}
      />
      {macs.length > 1 && pusher ? (
        <ControlPillMenu
          title="Mac that drives the card and sends alerts"
          actions={macActions}
          onPressAction={({ nativeEvent }) =>
            savePreferences({ infinitusLiveActivityMac: nativeEvent.event })
          }
        >
          <SettingsRow icon="desktopcomputer" label="Mac" value={pusher.label} onPress={() => {}} />
        </ControlPillMenu>
      ) : null}
    </SettingsSection>
  );
}
