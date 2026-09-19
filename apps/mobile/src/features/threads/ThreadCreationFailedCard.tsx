import { RequestActionButton } from "./RequestActionButton";
import { View } from "react-native";

import { AppText as Text } from "../../components/AppText";

/**
 * Shown in place of the composer when the server rejected a new task. The
 * prompt and attachments are already back in the project draft, so the only
 * action is reopening it.
 */
export function ThreadCreationFailedCard(props: {
  readonly reason: string;
  readonly onEditTask: () => void;
}) {
  return (
<<<<<<< HEAD
    <View className="gap-2.5 rounded-[20px] border border-adaptive-neutral-200-white-a6 bg-adaptive-neutral-100-900 p-4">
      <Text className="font-infinitus-bold text-2xs uppercase tracking-[1.1px] text-adaptive-rose-700-300">
=======
    <View className="gap-2.5 rounded-[20px] border border-border-subtle bg-card-alt p-4">
      <Text className="font-infinitus-bold text-2xs uppercase tracking-[1.1px] text-danger-foreground">
>>>>>>> upstream-sync-803f94e78-upstream-renamed
        Could not start task
      </Text>
      <Text className="font-sans text-sm leading-normal text-foreground-secondary">
        {props.reason}
      </Text>
      <Text className="font-sans text-xs leading-normal text-foreground-secondary">
        Your prompt was kept in the project draft.
      </Text>
      <View className="flex-row">
        <RequestActionButton label="Edit task" onPress={props.onEditTask} />
      </View>
    </View>
  );
}
