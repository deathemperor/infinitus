import { useAtomSet, useAtomValue } from "@effect/atom-react";
import type { MenuAction } from "@react-native-menu/menu";
import * as Effect from "effect/Effect";
import { AsyncResult } from "effect/unstable/reactivity";
import { useMemo, type ComponentProps } from "react";
import { Platform } from "react-native";

import { AndroidAnchoredMenu } from "../../components/AndroidAnchoredMenu";
import { ControlPillMenu } from "../../components/ControlPill";
import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../state/preferences";
import { environmentPresentations } from "../../state/presentation";
import { environmentServerConfigsAtom } from "../../state/server";
import {
  COMPOSER_SEND_MODE_LABELS,
  outboxQueueMode,
  type OutboxQueueMode,
} from "../../state/threadOutboxQueue.logic";
import { infinitusMacs } from "../accounts/accountsRoute.logic";
import { requestAgentNotificationPermission } from "../agent-awareness/notificationPermissions";
import { SettingsRow } from "./components/SettingsRow";
import { SettingsSwitchRow } from "./components/SettingsSwitchRow";

/**
 * A settings row that opens a menu of choices. iOS: `ControlPillMenu`'s
 * native `MenuView` opens on the tap whatever the row does, so the row's
 * press is a no-op. Android: `AndroidAnchoredMenu` wraps a plain child in
 * its own Pressable, which the row's inner Pressable would swallow, so the
 * row is handed `open` to call from its own press instead.
 */
function PickerRow(props: {
  readonly title: string;
  readonly actions: MenuAction[];
  readonly onPressAction: NonNullable<ComponentProps<typeof ControlPillMenu>["onPressAction"]>;
  readonly icon: ComponentProps<typeof SettingsRow>["icon"];
  readonly label: string;
  readonly value: string;
  readonly disabled?: boolean;
}) {
  const row = (open: () => void) => (
    <SettingsRow
      icon={props.icon}
      label={props.label}
      value={props.value}
      disabled={props.disabled}
      onPress={open}
    />
  );
  if (Platform.OS === "android") {
    return (
      <AndroidAnchoredMenu
        title={props.title}
        actions={props.actions}
        onPressAction={props.onPressAction}
      >
        {row}
      </AndroidAnchoredMenu>
    );
  }
  return (
    <ControlPillMenu
      title={props.title}
      actions={props.actions}
      onPressAction={props.onPressAction}
    >
      {row(() => {})}
    </ControlPillMenu>
  );
}

/** The fork's rows in Settings (#572): Accounts and Team beside Environments,
    the reset / swap alarms toggle (it asks for the notification permission)
    after the notification switches, the sending mode under General. All
    absent until a paired Mac runs Infinitus, so plain T3 users never see
    them. A Mac's account alerts and the lock-screen thread card ride
    Infinitus Connect's own Device Notifications and Live Activity switches
    (#1375). */
function useInfinitusMacPresent() {
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  return useMemo(() => infinitusMacs(configs, presentations).length > 0, [configs, presentations]);
}

export function InfinitusFleetRows() {
  if (!useInfinitusMacPresent()) return null;
  return (
    <>
      <SettingsRow icon="person.2" label="Accounts" target="SettingsAccounts" />
      <SettingsRow icon="person.3" label="Team" target="SettingsTeam" />
    </>
  );
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

/** Sending while a turn runs (#807, the desktop's `composerSendMode`). */
export function InfinitusSendModeRow() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const present = useInfinitusMacPresent();
  const loaded = AsyncResult.isSuccess(preferences);
  const sendMode = outboxQueueMode(preferences);
  const sendModeActions = useMemo<MenuAction[]>(
    () =>
      (["queue", "steer"] as const).map((mode) => ({
        id: mode,
        title: COMPOSER_SEND_MODE_LABELS[mode],
        state: mode === sendMode ? "on" : "off",
      })),
    [sendMode],
  );
  if (!present) return null;
  return (
    <PickerRow
      title="Sending while a turn runs"
      actions={sendModeActions}
      onPressAction={({ nativeEvent }) => {
        const mode = nativeEvent.event as OutboxQueueMode;
        if (mode === "queue" || mode === "steer")
          savePreferences({ infinitusComposerSendMode: mode });
      }}
      icon="tray.and.arrow.up"
      label="Sending while a turn runs"
      value={COMPOSER_SEND_MODE_LABELS[sendMode]}
      disabled={!loaded}
    />
  );
}
