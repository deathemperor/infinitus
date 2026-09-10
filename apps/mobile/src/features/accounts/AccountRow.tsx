import {
  type AccountAction,
  type AccountRowModel,
  accountCommandArgs,
  type UsageWindowBar,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import type { EnvironmentId } from "@t3tools/contracts";
import { useCallback, useState } from "react";
import { ActivityIndicator, Alert, Platform, Pressable, View } from "react-native";

import { SymbolView } from "../../components/AppSymbol";
import { AppText as Text } from "../../components/AppText";
import { showConfirmDialog } from "../../components/ConfirmDialogHost";
import { ControlPillMenu } from "../../components/ControlPill";
import { StatusPill } from "../../components/StatusPill";
import { cn } from "../../lib/cn";
import { infinitusEnvironment } from "../../state/infinitus";
import { useAtomCommand } from "../../state/use-atom-command";
import {
  commandFailureMessage,
  rowBadges,
  rowMenuActions,
  switchConfirmation,
  windowTone,
} from "./accountsRoute.logic";

const CAN_PROMPT = Platform.OS === "ios";

const BADGE_TONE = {
  active: {
    label: "Active",
    pillClassName: "bg-primary",
    textClassName: "text-primary-foreground",
  },
  next: { label: "Next", pillClassName: "bg-subtle-strong", textClassName: "text-foreground" },
  held: { label: "Held", pillClassName: "bg-warning", textClassName: "text-warning-foreground" },
  starred: { label: "★ First", pillClassName: "bg-subtle", textClassName: "text-foreground-muted" },
} as const;

const TONE_CLASS = {
  calm: "bg-primary",
  warm: "bg-warning",
  hot: "bg-danger",
} as const;

/** One account of one fleet: label, badges, usage bars, and the context menu
    that fires the engine's commands through the environment. */
export function AccountRow(props: {
  readonly environmentId: EnvironmentId;
  readonly fleetKey: string;
  readonly fleetTitle: string;
  readonly row: AccountRowModel;
  readonly last: boolean;
}) {
  const { environmentId, fleetKey, fleetTitle, row } = props;
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [busy, setBusy] = useState<AccountAction | null>(null);
  const [error, setError] = useState<string | null>(null);

  const perform = useCallback(
    async (action: AccountAction, alias?: string) => {
      const { command, args } = accountCommandArgs(fleetKey, row, action, alias);
      setBusy(action);
      setError(null);
      const result = await run({ environmentId, input: { command, args: [...args], options: {} } });
      setBusy(null);
      if (result._tag !== "Success") setError(commandFailureMessage(result.cause));
    },
    [environmentId, fleetKey, row, run],
  );

  const onAction = useCallback(
    (action: AccountAction) => {
      if (action === "switch") {
        const copy = switchConfirmation(row, fleetTitle);
        if (Platform.OS === "android") {
          showConfirmDialog({
            title: copy.title,
            message: copy.message,
            confirmText: "Switch",
            onConfirm: () => void perform("switch"),
          });
          return;
        }
        Alert.alert(copy.title, copy.message, [
          { text: "Cancel", style: "cancel" },
          { text: "Switch", onPress: () => void perform("switch") },
        ]);
        return;
      }
      if (action === "rename") {
        Alert.prompt(
          "Rename account",
          "The name Infinitus shows for this account.",
          (alias) => {
            const trimmed = alias?.trim() ?? "";
            if (trimmed.length > 0) void perform("rename", trimmed);
          },
          "plain-text",
          row.label,
        );
        return;
      }
      void perform(action);
    },
    [fleetTitle, perform, row],
  );

  const actions = rowMenuActions(row, { canPrompt: CAN_PROMPT });
  const badges = rowBadges(row);
  const content = (
    <View className={cn("gap-2 px-4 py-3", props.last ? null : "border-b border-separator")}>
      <View className="flex-row items-center gap-2">
        <Text className="shrink text-base font-t3-medium text-foreground" numberOfLines={1}>
          {row.label}
        </Text>
        {badges.map((badge) => (
          <StatusPill key={badge} size="compact" {...BADGE_TONE[badge]} />
        ))}
        <View className="flex-1" />
        {busy !== null ? (
          <ActivityIndicator size="small" />
        ) : actions.length > 0 ? (
          <SymbolView
            name="ellipsis.circle"
            size={18}
            tintColorClassName="accent-icon"
            type="monochrome"
          />
        ) : null}
      </View>
      {row.plan ? <Text className="text-xs text-foreground-muted">{row.plan}</Text> : null}
      {row.windows.map((window) => (
        <WindowBar key={window.name} window={window} />
      ))}
      {row.scoped.map((window) => (
        <WindowBar key={`scoped:${window.name}`} window={window} />
      ))}
      {row.freshness ? (
        <Text className="text-2xs text-foreground-tertiary">{row.freshness}</Text>
      ) : null}
      {error ? <Text className="text-xs text-danger-foreground">{error}</Text> : null}
    </View>
  );

  if (actions.length === 0) return content;
  return (
    <ControlPillMenu
      title={row.label}
      actions={[...actions]}
      onPressAction={({ nativeEvent }) => onAction(nativeEvent.event as AccountAction)}
      accessibilityRole="button"
      accessibilityLabel={`${row.label} actions`}
    >
      <Pressable className="active:opacity-70">{content}</Pressable>
    </ControlPillMenu>
  );
}

function WindowBar(props: { readonly window: UsageWindowBar }) {
  const { window } = props;
  return (
    <View className="flex-row items-center gap-2">
      <Text className="w-8 text-2xs font-t3-medium text-foreground-muted" numberOfLines={1}>
        {window.name}
      </Text>
      <View className="h-1.5 flex-1 overflow-hidden rounded-full bg-subtle">
        <View
          className={cn("h-full rounded-full", TONE_CLASS[windowTone(window.pct)])}
          style={{ width: `${window.pct}%` }}
        />
      </View>
      <Text className="w-9 text-right text-2xs tabular-nums text-foreground-muted">
        {window.pct}%
      </Text>
      {window.countdown ? (
        <Text className="w-14 text-2xs tabular-nums text-foreground-tertiary" numberOfLines={1}>
          {window.countdown}
        </Text>
      ) : null}
    </View>
  );
}
