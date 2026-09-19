import type { ReactNode } from "react";
import { Platform, View } from "react-native";

import { AppText as Text } from "../../../components/AppText";

export function SettingsSection(props: {
  readonly title?: string;
  readonly trailing?: ReactNode;
  readonly children: ReactNode;
}) {
  return (
    <View className="gap-2">
      {props.title ? (
        <View className="flex-row items-center justify-between gap-3">
          <Text
            className={
              Platform.OS === "android"
<<<<<<< HEAD
                ? "px-4 text-sm font-infinitus-medium text-primary"
=======
                ? "px-4 text-sm font-infinitus-medium text-primary-text"
>>>>>>> upstream-sync-803f94e78-upstream-renamed
                : "px-2 text-sm font-infinitus-medium text-foreground-muted"
            }
          >
            {props.title}
          </Text>
          {props.trailing}
        </View>
      ) : null}
      <View
        className={
          Platform.OS === "android"
            ? "overflow-hidden rounded-[28px] bg-grouped-card"
            : "overflow-hidden rounded-[24px] border-continuous bg-grouped-card"
        }
      >
        {props.children}
      </View>
    </View>
  );
}
