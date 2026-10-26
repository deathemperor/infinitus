import { useAtomSet, useAtomValue } from "@effect/atom-react";
import * as Effect from "effect/Effect";
import { AsyncResult } from "effect/reactivity";
import { useMemo } from "react";

import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../state/preferences";
import { environmentPresentations } from "../../state/presentation";
import { environmentServerConfigsAtom } from "../../state/server";
import { infinitusMacs } from "../accounts/accountsRoute.logic";
import { requestAgentNotificationPermission } from "../agent-awareness/notificationPermissions";
import { SettingsSwitchRow } from "./components/SettingsSwitchRow";

/** The fork's rows in Settings (#572): Accounts and Team, the reset / swap alarms toggle,
    and the sending mode. All absent until a paired Mac runs Infinitus, so plain T3 users
    never see them. */
function useInfinitusMacPresent() {
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  return useMemo(() => infinitusMacs(configs, presentations).length > 0, [configs, presentations]);
}

/** Accounts and Team as rows of upstream's searchable Settings list. */
export function useInfinitusFleetRows() {
  if (!useInfinitusMacPresent()) return [];
  return [
    { id: "SettingsAccounts", icon: "person.2", label: "Accounts", target: "SettingsAccounts" },
    { id: "SettingsTeam", icon: "person.3", label: "Team", target: "SettingsTeam" },
  ] as const;
}

export function InfinitusAlarmsRow() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const present = useInfinitusMacPresent();
  const loaded = AsyncResult.isSuccess(preferences);
  const alarmsEnabled = loaded && preferences.value.infinitusAlarmsEnabled === true;
  if (!present) return null;
  return (
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
  );
}
