import {
  nudgeOutcome,
  type SessionRowModel,
} from "@t3tools/client-runtime/state/infinitusSessions";
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
  type MacSessionsView,
  sessionChoiceCommand,
  sessionMenuActions,
  sessionMenuChoice,
  sessionRowDetail,
} from "./sessions.logic";

const STATE_DOT: Record<SessionRowModel["state"], string> = {
  waiting: "bg-warning",
  working: "bg-primary",
  idle: "bg-subtle-strong",
  shell: "bg-subtle-strong",
  unknown: "bg-subtle",
};

/** One Mac's live Claude Code sessions (the snapshot's `sessions`), the ones
    needing a person first. A row's context menu offers what this build's
    manifest lists: open its chat window on the Mac (`show session <pid>`),
    the resume nudge by hand (`nudge <pid>`), and its permission mode
    (`session-mode`). */
export function InfinitusSessions(props: {
  readonly environmentId: EnvironmentId;
  readonly view: MacSessionsView;
}) {
  const { environmentId, view } = props;
  return (
    <SettingsSection title="Sessions" card>
      {view.attentionCount > 0 ? (
        <View className="border-b border-separator px-4 py-2">
          <StatusPill
            size="compact"
            label={`${view.attentionCount} need you`}
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
          view={view}
          last={index === view.rows.length - 1}
        />
      ))}
    </SettingsSection>
  );
}

function SessionRow(props: {
  readonly environmentId: EnvironmentId;
  readonly row: SessionRowModel;
  readonly view: MacSessionsView;
  readonly last: boolean;
}) {
  const { environmentId, row } = props;
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);

  const choose = async (id: string) => {
    const choice = sessionMenuChoice(id);
    if (choice === null) return;
    const input = sessionChoiceCommand(row, choice);
    if (input === null) return;
    setBusy(true);
    setNote(null);
    const result = await run({ environmentId, input });
    setBusy(false);
    if (result._tag !== "Success") {
      setNote(commandFailureMessage(result.cause));
      return;
    }
    if (choice.kind === "nudge") {
      const outcome = nudgeOutcome(result.value.result);
      if (!outcome.nudged) setNote(outcome.reason ?? "The session was not nudged.");
    }
  };

  const actions = sessionMenuActions(row, props.view.actions);
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
        ) : actions.length > 0 ? (
          <SymbolView
            name="ellipsis.circle"
            size={18}
            tintColorClassName="accent-icon"
            type="monochrome"
          />
        ) : null}
      </View>
      <Text className="text-xs text-foreground-muted" numberOfLines={1}>
        {sessionRowDetail(row)}
      </Text>
      {row.needs.map((need) => (
        <Text key={need} className="text-xs text-warning-foreground">
          {need}
        </Text>
      ))}
      {note ? <Text className="text-xs text-danger-foreground">{note}</Text> : null}
    </View>
  );

  if (actions.length === 0) return content;
  return (
    <ControlPillMenu
      title={row.title}
      actions={[...actions]}
      onPressAction={({ nativeEvent }) => void choose(nativeEvent.event)}
      accessibilityRole="button"
      accessibilityLabel={`${row.title} actions`}
    >
      <Pressable className="active:opacity-70">{content}</Pressable>
    </ControlPillMenu>
  );
}
