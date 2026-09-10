import type { SessionRowModel } from "@t3tools/client-runtime/state/infinitusSessions";
import type { EnvironmentId } from "@t3tools/contracts";
import { useState } from "react";
import { ActivityIndicator, Pressable, View } from "react-native";

import { SymbolView } from "../../components/AppSymbol";
import { AppText as Text } from "../../components/AppText";
import { ControlPillMenu } from "../../components/ControlPill";
import { StatusPill } from "../../components/StatusPill";
import { cn } from "../../lib/cn";
import { infinitusEnvironment } from "../../state/infinitus";
import { useAtomCommand } from "../../state/use-atom-command";
import { commandFailureMessage } from "../accounts/accountsRoute.logic";
import { SettingsSection } from "../settings/components/SettingsSection";
import {
  isSessionPermissionMode,
  type MacSessionsView,
  sessionModeCommand,
  sessionModeMenuActions,
} from "./sessions.logic";

const STATE_DOT: Record<SessionRowModel["state"], string> = {
  waiting: "bg-warning",
  working: "bg-primary",
  idle: "bg-subtle-strong",
  shell: "bg-subtle-strong",
  unknown: "bg-subtle",
};

/** One Mac's live Claude Code sessions (the snapshot's `sessions`), waiting
    ones first; a row's context menu sets its permission mode through the
    manifest's `session-mode` verb, the one per-session write the app exposes
    that is neither stdin text nor destructive. */
export function InfinitusSessions(props: {
  readonly environmentId: EnvironmentId;
  readonly view: MacSessionsView;
}) {
  const { environmentId, view } = props;
  return (
    <SettingsSection title="Sessions" card>
      {view.waitingCount > 0 ? (
        <View className="border-b border-separator px-4 py-2">
          <StatusPill
            size="compact"
            label={`${view.waitingCount} waiting on you`}
            pillClassName="bg-warning"
            textClassName="text-warning-foreground"
          />
        </View>
      ) : null}
      {view.rows.map((row, index) => (
        <SessionRow
          key={row.pid}
          environmentId={environmentId}
          row={row}
          canSetMode={view.canSetMode}
          last={index === view.rows.length - 1}
        />
      ))}
    </SettingsSection>
  );
}

function SessionRow(props: {
  readonly environmentId: EnvironmentId;
  readonly row: SessionRowModel;
  readonly canSetMode: boolean;
  readonly last: boolean;
}) {
  const { environmentId, row } = props;
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const setMode = async (id: string) => {
    if (!isSessionPermissionMode(id)) return;
    const input = sessionModeCommand(row, id);
    if (input === null) return;
    setBusy(true);
    setError(null);
    const result = await run({ environmentId, input });
    setBusy(false);
    if (result._tag !== "Success") setError(commandFailureMessage(result.cause));
  };

  const content = (
    <View className={cn("gap-1 px-4 py-3", props.last ? null : "border-b border-separator")}>
      <View className="flex-row items-center gap-2">
        <View className={cn("size-2 rounded-full", STATE_DOT[row.state])} />
        <Text className="shrink text-base font-t3-medium text-foreground" numberOfLines={1}>
          {row.title}
        </Text>
        <View className="flex-1" />
        {busy ? (
          <ActivityIndicator size="small" />
        ) : props.canSetMode ? (
          <SymbolView
            name="ellipsis.circle"
            size={18}
            tintColorClassName="accent-icon"
            type="monochrome"
          />
        ) : null}
      </View>
      <Text className="text-xs text-foreground-muted" numberOfLines={1}>
        {row.title === row.folder ? row.stateLabel : `${row.stateLabel} · ${row.folder}`}
      </Text>
      {error ? <Text className="text-xs text-danger-foreground">{error}</Text> : null}
    </View>
  );

  if (!props.canSetMode) return content;
  return (
    <ControlPillMenu
      title={`${row.title} · permission mode`}
      actions={[...sessionModeMenuActions(row)]}
      onPressAction={({ nativeEvent }) => void setMode(nativeEvent.event)}
      accessibilityRole="button"
      accessibilityLabel={`${row.title} permission mode`}
    >
      <Pressable className="active:opacity-70">{content}</Pressable>
    </ControlPillMenu>
  );
}
