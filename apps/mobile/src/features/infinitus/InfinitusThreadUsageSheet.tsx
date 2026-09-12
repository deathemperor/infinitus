import { EnvironmentId, ThreadId } from "@t3tools/contracts";
import { useNavigation, type StaticScreenProps } from "@react-navigation/native";
import { useMemo } from "react";
import { Platform, ScrollView, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { AndroidSheetHeader } from "../../components/AndroidScreenHeader";
import { AppText as Text } from "../../components/AppText";
import { useThreadShell } from "../../state/entities";
import { MetaCard } from "../threads/git/gitSheetComponents";
import { threadUsageNotes, threadUsageRows } from "./threadUsage.logic";

type ThreadUsageSheetProps = StaticScreenProps<{
  readonly environmentId: string;
  readonly threadId: string;
}>;

/**
 * Fork (#834): a thread's usage as a sheet over it — the completed turns'
 * tokens, cost and models the server rolls up on the shell. The shell is
 * live (every refetch carries the rollup and the reducer applies
 * `thread.turn-usage-recorded`), so the sheet reads it and requests nothing.
 * A thread with no recorded turn says so; every number shown is an estimate.
 */
export function InfinitusThreadUsageSheet(props: ThreadUsageSheetProps) {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const ref = useMemo(
    () => ({
      environmentId: EnvironmentId.make(props.route.params.environmentId),
      threadId: ThreadId.make(props.route.params.threadId),
    }),
    [props.route.params.environmentId, props.route.params.threadId],
  );
  const usage = useThreadShell(ref)?.usage;

  return (
    <View collapsable={false} className="flex-1 bg-sheet">
      {Platform.OS === "android" ? (
        <AndroidSheetHeader title="Thread usage" onBack={() => navigation.goBack()} />
      ) : null}
      <ScrollView
        className="flex-1"
        showsVerticalScrollIndicator={false}
        contentInset={{ bottom: Math.max(insets.bottom, 18) + 18 }}
        contentContainerClassName="gap-4 px-5 pt-2"
      >
        {usage === undefined ? (
          <Text className="py-6 text-center text-sm leading-normal text-foreground-muted">
            No completed turn recorded yet.
          </Text>
        ) : (
          <>
            <View className="gap-2">
              {threadUsageRows(usage).map((row) => (
                <MetaCard key={row.label} label={row.label} value={row.value} />
              ))}
            </View>
            <View className="gap-1 px-1">
              {threadUsageNotes(usage).map((note) => (
                <Text key={note} className="text-xs leading-snug text-foreground-muted">
                  {note}
                </Text>
              ))}
            </View>
          </>
        )}
      </ScrollView>
    </View>
  );
}
