import type { EnvironmentId, OrchestrationThreadShell } from "@t3tools/contracts";
import { Pressable, View } from "react-native";

import { SymbolView } from "../../components/AppSymbol";
import { AppText as Text } from "../../components/AppText";
import { queuedTurnSnippet, queuedTurnsTitle } from "./queuedTurns.logic";
import { useQueuedTurnActions } from "./useQueuedTurnActions";

/**
 * The composer card listing a thread's server-side queue (#806, the web's
 * `ComposerSendQueue`): one row per queued message in send order with
 * earlier/later (when more than one), edit, send now and remove. Renders
 * nothing while the thread has no rows. Mounted from ThreadRouteScreen
 * through ThreadDetailScreen's `infinitusQueuedTurns` slot.
 */
export function InfinitusQueuedTurns(props: {
  readonly environmentId: EnvironmentId;
  readonly thread: OrchestrationThreadShell;
}) {
  const { environmentId, thread } = props;
  const actions = useQueuedTurnActions({ environmentId, thread });
  if (actions.rows.length === 0) return null;
  const threadRunning =
    thread.session?.status === "running" || thread.session?.status === "starting";
  const canMove = actions.rows.length > 1;

  return (
    <View className="gap-2.5 rounded-[20px] border border-adaptive-neutral-200-white-a6 bg-adaptive-neutral-100-900 p-4">
      <Text className="font-t3-bold text-2xs uppercase tracking-[1.1px] text-adaptive-neutral-600-400">
        {queuedTurnsTitle(actions.rows.length, threadRunning)}
      </Text>
      {actions.rows.map((row, index) => (
        <View key={row.queueId} className="flex-row items-center gap-2">
          <Text
            className="flex-1 font-sans text-sm leading-normal text-foreground"
            numberOfLines={2}
          >
            {queuedTurnSnippet(row)}
          </Text>
          {canMove ? (
            <>
              <IconButton
                label="Send earlier"
                symbol="chevron.up"
                disabled={index === 0}
                onPress={() => actions.move(row, "earlier")}
              />
              <IconButton
                label="Send later"
                symbol="chevron.down"
                disabled={index === actions.rows.length - 1}
                onPress={() => actions.move(row, "later")}
              />
            </>
          ) : null}
          <IconButton label="Edit" symbol="pencil" onPress={() => actions.edit(row)} />
          <IconButton label="Send now" symbol="arrow.up" onPress={() => actions.sendNow(row)} />
          <IconButton label="Remove" symbol="xmark" onPress={() => actions.remove(row)} />
        </View>
      ))}
    </View>
  );
}

function IconButton(props: {
  readonly label: string;
  readonly symbol: "chevron.up" | "chevron.down" | "pencil" | "arrow.up" | "xmark";
  readonly disabled?: boolean;
  readonly onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={props.label}
      disabled={props.disabled}
      hitSlop={6}
      className={`h-8 w-8 items-center justify-center rounded-full border border-adaptive-neutral-200-white-a6 ${props.disabled ? "opacity-30" : "active:opacity-70"}`}
      onPress={props.onPress}
    >
      <SymbolView name={props.symbol} size={15} tintColorClassName="accent-icon" />
    </Pressable>
  );
}
