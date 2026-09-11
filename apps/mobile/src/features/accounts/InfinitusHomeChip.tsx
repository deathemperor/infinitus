import { useAtomValue } from "@effect/atom-react";
import { useNavigation } from "@react-navigation/native";
import type { EnvironmentId } from "@t3tools/contracts";
import { useMemo } from "react";
import { Pressable, View } from "react-native";

import { SymbolView } from "../../components/AppSymbol";
import { AppText as Text } from "../../components/AppText";
import { cn } from "../../lib/cn";
import { infinitusEnvironment } from "../../state/infinitus";
import { environmentPresentations } from "../../state/presentation";
import { useEnvironmentQuery } from "../../state/query";
import { environmentServerConfigsAtom } from "../../state/server";
import { attentionSessionCount } from "../infinitus/sessions.logic";
import { chipEnvironment, homeChip, infinitusMacs } from "./accountsRoute.logic";
import { useNowMinute } from "./useNowMinute";

const PCT_CLASS = {
  calm: "text-foreground-muted",
  warm: "text-warning-foreground",
  hot: "text-danger-foreground",
  off: "text-foreground-tertiary",
} as const;

/** The home header's Infinitus chip: the active account of the Mac the list
    follows, its fullest usage window ("limited" while every account is at a
    limit, #706), and how many of its sessions wait on a person; tap →
    Settings › Accounts. Renders nothing when no paired Mac runs Infinitus. */
export function InfinitusHomeChip(props: { readonly selectedEnvironmentId: EnvironmentId | null }) {
  const navigation = useNavigation();
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const mac = useMemo(
    () => chipEnvironment(props.selectedEnvironmentId, infinitusMacs(configs, presentations)),
    [configs, presentations, props.selectedEnvironmentId],
  );
  const view = useEnvironmentQuery(
    mac === null
      ? null
      : infinitusEnvironment.snapshot({ environmentId: mac.environmentId, input: {} }),
  );
  const now = useNowMinute();
  const model = homeChip(mac === null ? null : view.data, now);
  const waiting = attentionSessionCount(mac === null ? null : view.data);
  if (mac === null || model === null) return null;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`Infinitus accounts on ${mac.label}`}
      onPress={() =>
        navigation.navigate("SettingsSheet", {
          screen: "SettingsContent",
          params: { screen: "SettingsAccounts" },
        })
      }
      className="h-11 max-w-[160px] flex-row items-center gap-1.5 rounded-full bg-subtle px-3 active:opacity-70"
    >
      <SymbolView
        name={model.tone === "off" ? "bolt.slash" : "bolt.fill"}
        size={14}
        tintColorClassName="accent-icon"
        type="monochrome"
      />
      <Text className="shrink text-sm font-t3-medium text-foreground" numberOfLines={1}>
        {model.label}
      </Text>
      {model.limited ? (
        <Text className={cn("text-sm font-t3-bold", PCT_CLASS.hot)}>limited</Text>
      ) : model.pct !== null ? (
        <Text className={cn("text-sm font-t3-bold tabular-nums", PCT_CLASS[model.tone])}>
          {model.pct}%
        </Text>
      ) : null}
      {waiting > 0 ? (
        <View className="rounded-full bg-warning px-1.5">
          <Text className="text-xs font-t3-bold tabular-nums text-warning-foreground">
            {waiting}
          </Text>
        </View>
      ) : null}
    </Pressable>
  );
}
