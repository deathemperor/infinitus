import type { EnvironmentId, ThreadId } from "@infinitus/contracts";
import { threadUsageFromProjection } from "@infinitus/shared/threadUsage";
import { useMemo } from "react";
import { View } from "react-native";

import { AppText as Text } from "../../components/ui/AppText";
import { useThreadProjection } from "../../state/use-thread-detail";
import { threadUsageNotes, threadUsageRows } from "./threadUsage.logic";

/**
 * Fork (#834): a thread's usage under the options of its settings sheet —
 * the completed turns' tokens, cost, models, tool calls and time working,
 * folded by the client from the live projection it already holds, so
 * nothing is requested for it. Mounted only by the existing-thread host (a
 * draft or a scheduled task has no turns), and drawn only once a turn was
 * recorded: an empty card would be a lying affordance.
 */
export function InfinitusThreadUsageRows(props: {
  readonly environmentId: EnvironmentId;
  readonly threadId: ThreadId;
}) {
  const thread = useThreadProjection(props);
  const projection = thread?.projection;
  const usage = useMemo(
    () => (projection === undefined ? undefined : threadUsageFromProjection(projection)),
    [projection],
  );
  if (usage === undefined) return null;
  return (
    <>
      <Text className="px-5 pb-2 pt-7 text-sm font-infinitus-medium text-foreground-muted">
        Usage
      </Text>
      <View className="mx-4 gap-2">
        {threadUsageRows(usage).map((row) => (
          <UsageCard key={row.label} label={row.label} value={row.value} />
        ))}
      </View>
      <View className="gap-1 px-5 pt-2">
        {threadUsageNotes(usage).map((note) => (
          <Text key={note} className="text-xs leading-snug text-foreground-muted">
            {note}
          </Text>
        ))}
      </View>
    </>
  );
}

/** One labelled value, the card the git sheet drew before upstream dropped it. */
function UsageCard(props: { readonly label: string; readonly value: string }) {
  return (
    <View className="bg-card px-4 py-3 android:rounded-[20px] ios:rounded-[18px] ios:border ios:border-border">
      <Text className="text-foreground-muted text-2xs font-infinitus-bold tracking-[0.9px] uppercase">
        {props.label}
      </Text>
      <Text selectable className="text-foreground text-sm font-medium" numberOfLines={1}>
        {props.value}
      </Text>
    </View>
  );
}
