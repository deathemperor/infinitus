import { useMemo } from "react";

import type { AndroidHeaderAction } from "../../components/AndroidScreenHeader";
import type { AppSymbolName } from "../../components/AppSymbol";
import { withNativeGlassHeaderItem } from "../layout/native-glass-header-items";
import {
  threadHeaderMenu,
  type ThreadMenuAction,
  type ThreadMenuPullRequest,
} from "./threadHeaderMenu.logic";

export interface ThreadHeaderMenu {
  /** The one iOS header item, or null with nothing to offer. */
  readonly item: Record<string, unknown> | null;
  /** The Android in-flow header's button, opening the same choices anchored. */
  readonly androidAction: AndroidHeaderAction | null;
  /** Feeds `optionsVersion`: the header re-reads the item only when this changes. */
  readonly version: string;
}

const NONE: ThreadHeaderMenu = { item: null, androidAction: null, version: "" };

/**
 * Fork (#941 walk): the thread header's Infinitus choices as one menu button
 * — see `threadHeaderMenu`. The inputs are what the PR, side-question and
 * usage hooks answer; their versions fold into this one.
 */
export function useThreadHeaderMenu(input: {
  readonly pullRequest: { readonly menu: ThreadMenuPullRequest | null; readonly version: string };
  readonly sideQuestion: { readonly action: ThreadMenuAction | null; readonly version: string };
  readonly usage: { readonly action: ThreadMenuAction | null; readonly version: string };
}): ThreadHeaderMenu {
  const { pullRequest, sideQuestion, usage } = input;
  return useMemo<ThreadHeaderMenu>(() => {
    const model = threadHeaderMenu({
      pullRequest: pullRequest.menu,
      threadActions: [sideQuestion.action, usage.action].filter((action) => action !== null),
    });
    if (model === null) return NONE;
    return {
      item: withNativeGlassHeaderItem({
        accessibilityLabel: model.accessibilityLabel,
        icon: { name: model.icon, type: "sfSymbol" as const },
        identifier: "thread-right-infinitus-menu",
        ...(model.label === null ? {} : { label: model.label }),
        menu: {
          ...(model.title === undefined ? {} : { title: model.title }),
          items: model.actions.map((action) => ({
            ...(action.description === undefined ? {} : { description: action.description }),
            ...(action.disabled === true ? { disabled: true } : {}),
            icon: { name: action.icon, type: "sfSymbol" as const },
            label: action.label,
            onPress: action.onPress,
            type: "action" as const,
          })),
        },
        type: "menu" as const,
      }),
      androidAction: {
        accessibilityLabel: model.accessibilityLabel,
        icon: model.icon as AppSymbolName,
        onPress: (): void => {},
        menu: {
          ...(model.title === undefined ? {} : { title: model.title }),
          actions: model.actions.map((action) => ({
            id: action.id,
            title: action.label,
            ...(action.description === undefined ? {} : { subtitle: action.description }),
            ...(action.disabled === true ? { attributes: { disabled: true } } : {}),
          })),
          onPressAction: ({ nativeEvent }): void => {
            model.actions.find((action) => action.id === nativeEvent.event)?.onPress();
          },
        },
      },
      version: [pullRequest.version, sideQuestion.version, usage.version].join("|"),
    };
  }, [pullRequest, sideQuestion, usage]);
}
