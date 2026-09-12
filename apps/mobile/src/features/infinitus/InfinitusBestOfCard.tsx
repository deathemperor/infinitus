import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";
import { CommonActions, useNavigation } from "@react-navigation/native";
import { useMemo } from "react";
import { Pressable, View } from "react-native";

import { AppText as Text } from "../../components/AppText";
import { SymbolView } from "../../components/AppSymbol";
import { useThreadShells } from "../../state/entities";
import {
  BEST_OF_STATUS_LABEL,
  bestOfCardShown,
  bestOfMemberStatus,
  bestOfSiblings,
} from "./bestOf.logic";

/**
 * Best of N on the phone (#269 B), read-only: the card on a member thread
 * listing the group's live siblings — title (the draft's title with the
 * model), one word of status, a tap opens the sibling. No "Keep this one":
 * that removes worktrees and stays on the desktop. Nothing while this
 * thread is the only live member.
 */
export function InfinitusBestOfCard(props: { readonly thread: EnvironmentThreadShell }) {
  const { thread } = props;
  const navigation = useNavigation();
  const shells = useThreadShells();
  const siblings = useMemo(
    () =>
      thread.groupId == null
        ? []
        : bestOfSiblings(
            shells.filter((shell) => shell.environmentId === thread.environmentId),
            thread.groupId,
          ),
    [shells, thread.environmentId, thread.groupId],
  );
  if (!bestOfCardShown(siblings, thread.id)) return null;
  return (
    <View className="rounded-[18px] border border-border bg-card px-4 py-3">
      <Text className="text-foreground-muted text-2xs font-t3-bold tracking-[0.9px] uppercase">
        Best of {siblings.length}
      </Text>
      {siblings.map((sibling) => {
        const current = sibling.id === thread.id;
        return (
          <Pressable
            key={sibling.id}
            accessibilityRole="button"
            accessibilityLabel={`${sibling.title}, ${BEST_OF_STATUS_LABEL[bestOfMemberStatus(sibling)]}`}
            disabled={current}
            className="flex-row items-center gap-3 py-2 active:opacity-70"
            onPress={() =>
              navigation.dispatch(
                CommonActions.navigate("Thread", {
                  environmentId: sibling.environmentId,
                  threadId: sibling.id,
                }),
              )
            }
          >
            <Text
              className={
                current
                  ? "text-foreground flex-1 text-sm font-t3-bold"
                  : "text-foreground flex-1 text-sm"
              }
              numberOfLines={1}
            >
              {sibling.title}
            </Text>
            <Text className="text-foreground-muted text-xs">
              {BEST_OF_STATUS_LABEL[bestOfMemberStatus(sibling)]}
            </Text>
            {current ? null : (
              <SymbolView
                name="chevron.right"
                size={12}
                tintColorClassName={"accent-icon-subtle"}
                type="monochrome"
              />
            )}
          </Pressable>
        );
      })}
    </View>
  );
}
