import { useAtomSet, useAtomValue } from "@effect/atom-react";
import type { MenuAction } from "@react-native-menu/menu";
import { AsyncResult } from "effect/unstable/reactivity";
import { useMemo } from "react";
import { Platform } from "react-native";

import { ControlPillMenu } from "../../components/ControlPill";
import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../state/preferences";
import { environmentPresentations } from "../../state/presentation";
import { environmentServerConfigsAtom } from "../../state/server";
import { infinitusMacs } from "../accounts/accountsRoute.logic";
import { pusherMac } from "../infinitus/liveActivity.logic";
import { SettingsRow } from "./components/SettingsRow";
import { SettingsSection } from "./components/SettingsSection";
import { SettingsSwitchRow } from "./components/SettingsSwitchRow";

/** Settings › Infinitus (fork, #572): the Live Activity toggle and, with
    several Macs, which one drives the cards. Absent until a paired Mac runs
    Infinitus, so plain T3 users never see it. */
export function SettingsInfinitusSection() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const macs = useMemo(() => infinitusMacs(configs, presentations), [configs, presentations]);
  const loaded = AsyncResult.isSuccess(preferences);
  const enabled = loaded && preferences.value.infinitusLiveActivityEnabled !== false;
  const pusher = pusherMac(loaded ? preferences.value.infinitusLiveActivityMac : undefined, macs);
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
      {macs.length > 1 && pusher ? (
        <ControlPillMenu
          title="Mac that drives the card"
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
