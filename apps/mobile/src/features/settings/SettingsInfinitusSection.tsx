import { useAtomSet, useAtomValue } from "@effect/atom-react";
import type { MenuAction } from "@react-native-menu/menu";
import * as Effect from "effect/Effect";
import { AsyncResult } from "effect/unstable/reactivity";
import { useCallback, useMemo, useState, type ComponentProps } from "react";
import { Alert, Platform } from "react-native";

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
import { pusherMac } from "../infinitus/liveActivity.logic";
import { noteLocalLiveActivityChange } from "../infinitus/liveActivityStarts";
import { agentActivityPushAtom } from "../infinitus/pushDiagnostics";
import { agentActivityPushSummary } from "../infinitus/pushDiagnostics.logic";
import { testCardLabel, toggleTestCard } from "../infinitus/testCard.logic";
import AgentActivity from "../../widgets/AgentActivity";
import { SettingsRow } from "./components/SettingsRow";
import { SettingsSection } from "./components/SettingsSection";
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

/** How many thread cards are live right now (iOS only; the factory is a
    no-op elsewhere). */
function countLiveCards(): number {
  return Platform.OS === "ios" ? AgentActivity.getInstances().length : 0;
}

/** Settings › Infinitus (fork, #572): the Mac alerts toggle (#702), the
    lock-screen thread card toggle with its test card (#1047), the reset /
    swap alarms toggle (the two banner ones ask for the notification
    permission) and, with several Macs, which one sends the alerts. Absent
    until a paired Mac runs Infinitus, so plain T3 users never see it. */
export function SettingsInfinitusSection() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const macs = useMemo(() => infinitusMacs(configs, presentations), [configs, presentations]);
  const loaded = AsyncResult.isSuccess(preferences);
  const alarmsEnabled = loaded && preferences.value.infinitusAlarmsEnabled === true;
  const pushAlertsEnabled = loaded && preferences.value.infinitusPushAlertsEnabled === true;
  const threadCardEnabled = loaded && preferences.value.infinitusThreadCardEnabled !== false;
  const pushSummary = agentActivityPushSummary(useAtomValue(agentActivityPushAtom));
  const pusher = pusherMac(loaded ? preferences.value.infinitusLiveActivityMac : undefined, macs);
  // The test-card row (#845, #1047): how many thread cards are live,
  // re-read after every press; the count is what the row offers to end.
  const [liveCards, setLiveCards] = useState(countLiveCards);
  const pressTestCard = useCallback(async () => {
    const outcome = await toggleTestCard(AgentActivity);
    setLiveCards(countLiveCards());
    // The bridge re-scans and files the new card's token with the Mac.
    if (outcome.action !== "failed") noteLocalLiveActivityChange();
    if (outcome.action === "failed") {
      Alert.alert("No card", `iOS refused the Live Activity: ${outcome.message}`);
    }
  }, []);
  // Sending while a turn runs (#807, the desktop's `composerSendMode`).
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
        icon="bolt.badge.clock"
        label="Thread card on the lock screen"
        subtitle={
          Platform.OS === "ios"
            ? "The Mac keeps a card of what your threads are doing moving over push, app closed."
            : "Live Activities are an iOS feature."
        }
        disabled={Platform.OS !== "ios" || !loaded}
        value={threadCardEnabled}
        onValueChange={(value) => savePreferences({ infinitusThreadCardEnabled: value })}
      />
      {Platform.OS === "ios" ? (
        <SettingsRow
          icon="rectangle.badge.checkmark"
          label={testCardLabel(liveCards)}
          value={liveCards === 0 ? "No push involved" : `${liveCards} live`}
          disabled={!threadCardEnabled}
          onPress={() => void pressTestCard()}
        />
      ) : null}
      {Platform.OS === "ios" ? (
        <SettingsRow
          icon="antenna.radiowaves.left.and.right"
          label="Card push registration"
          value={pushSummary.value}
          onPress={() => Alert.alert("Card push registration", pushSummary.explanation)}
        />
      ) : null}
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
      {macs.length > 1 && pusher ? (
        <PickerRow
          title="Mac that sends the alerts"
          actions={macActions}
          onPressAction={({ nativeEvent }) =>
            savePreferences({ infinitusLiveActivityMac: nativeEvent.event })
          }
          icon="desktopcomputer"
          label="Mac"
          value={pusher.label}
        />
      ) : null}
    </SettingsSection>
  );
}
