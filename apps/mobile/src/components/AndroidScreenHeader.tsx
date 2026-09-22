import { useState, type ReactNode } from "react";
import { View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import type { AppSymbolName } from "./AppSymbol";
import { AppText as Text } from "./AppText";
import { cn } from "../lib/cn";
import { MaterialIconButton } from "./MaterialIconButton";
import { AndroidAnchoredMenu, type AndroidAnchoredMenuProps } from "./AndroidAnchoredMenu";
import { useScaledTextRole } from "../features/settings/appearance/useScaledTextRole";
import { useMaterialToolbarHeight } from "./useMaterialToolbarHeight";

export interface AndroidHeaderAction {
  readonly accessibilityLabel: string;
  readonly icon: AppSymbolName;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  readonly selected?: boolean;
  /** Infinitus (fork, #269 F): an action whose tap opens an anchored menu of
      these choices instead of running `onPress` — the Android form of an
      iOS header menu item, with no cap on the number of choices (an
      `Alert` shows at most three buttons). Such an action folds into the
      overflow menu as a submenu, never as a flat row whose tap would run
      the no-op `onPress` these call sites pass. */
  readonly menu?: Pick<AndroidAnchoredMenuProps, "actions" | "title" | "onPressAction">;
}

export function AndroidHeaderIconButton(props: {
  readonly accessibilityLabel: string;
  readonly icon: AppSymbolName;
  readonly onPress?: () => void;
  readonly disabled?: boolean;
  readonly selected?: boolean;
}) {
  return <MaterialIconButton {...props} tintColorClassName="accent-header-foreground" />;
}

export function AndroidScreenHeader(props: {
  readonly title: string;
  readonly subtitle?: string | null;
  readonly actions?: ReadonlyArray<AndroidHeaderAction>;
  readonly leading?: ReactNode;
  readonly trailing?: ReactNode;
  readonly onBack?: () => void;
  readonly embedded?: boolean;
  readonly hideBottomBorder?: boolean;
}) {
  const insets = useSafeAreaInsets();
  const titleTypography = useScaledTextRole("title");
  const subtitleTypography = useScaledTextRole("label");
  const materialToolbarHeight = useMaterialToolbarHeight();
  const [headerWidth, setHeaderWidth] = useState(0);
  const actions = props.actions ?? [];
  const directCount = actions.length > 2 ? (headerWidth >= 600 ? 3 : 1) : actions.length;
  const visibleActions = actions.slice(0, directCount);
  const overflowActions = actions.slice(directCount);

  return (
    <View
      onLayout={(event) => setHeaderWidth(event.nativeEvent.layout.width)}
      className="border-b border-header-border bg-header px-2 pb-2"
      style={{
        paddingTop: props.embedded ? 8 : Math.max(insets.top, 12),
        borderBottomWidth: props.hideBottomBorder ? 0 : undefined,
      }}
    >
      <View
        style={{ minHeight: materialToolbarHeight }}
        className="min-h-14 flex-row items-center gap-1"
      >
        {props.onBack ? (
          <MaterialIconButton
            accessibilityLabel="Navigate up"
            icon="arrow.left"
            tintColorClassName="accent-header-foreground"
            onPress={props.onBack}
          />
        ) : null}

        {props.leading}

        <View className={cn("min-w-0 flex-1", !props.onBack && "pl-1")}>
          <Text numberOfLines={1} style={titleTypography} className="text-header-foreground">
            {props.title}
          </Text>
          {props.subtitle ? (
            <Text
              numberOfLines={1}
              style={subtitleTypography}
              className="mt-px text-[13px] font-infinitus-medium text-foreground-muted"
            >
              {props.subtitle}
            </Text>
          ) : null}
        </View>

        {visibleActions.map((action) =>
          action.menu ? (
            <AndroidAnchoredMenu
              key={action.accessibilityLabel}
              actions={action.menu.actions}
              title={action.menu.title}
              onPressAction={action.menu.onPressAction}
            >
              {(open) => (
                <AndroidHeaderIconButton
                  accessibilityLabel={action.accessibilityLabel}
                  disabled={action.disabled}
                  selected={action.selected}
                  icon={action.icon}
                  onPress={open}
                />
              )}
            </AndroidAnchoredMenu>
          ) : (
            <AndroidHeaderIconButton
              key={action.accessibilityLabel}
              accessibilityLabel={action.accessibilityLabel}
              disabled={action.disabled}
              selected={action.selected}
              icon={action.icon}
              onPress={action.onPress}
            />
          ),
        )}
        {overflowActions.length > 0 ? (
          <AndroidAnchoredMenu
            actions={overflowActions.map((action, index) => ({
              id: String(index),
              title: action.accessibilityLabel,
              attributes: {
                disabled: Boolean(action.disabled),
                state: action.selected ? "on" : undefined,
              },
              ...(action.menu === undefined ? {} : { subactions: [...action.menu.actions] }),
            }))}
            onPressAction={(event) => {
              // A submenu row reports its own id, not the parent's index, so
              // the owning action's handler gets the event before the
              // index lookup a flat row needs.
              const owner = overflowActions.find((action) =>
                action.menu?.actions.some((item) => item.id === event.nativeEvent.event),
              );
              if (owner?.menu?.onPressAction) {
                owner.menu.onPressAction(event);
                return;
              }
              overflowActions[Number(event.nativeEvent.event)]?.onPress();
            }}
          >
            {(open) => (
              <MaterialIconButton
                accessibilityLabel="More actions"
                icon="ellipsis"
                tintColorClassName="accent-header-foreground"
                onPress={open}
              />
            )}
          </AndroidAnchoredMenu>
        ) : null}
        {props.trailing}
      </View>
    </View>
  );
}

export function AndroidSheetHeader(
  props: Omit<Parameters<typeof AndroidScreenHeader>[0], "embedded">,
) {
  return <AndroidScreenHeader {...props} embedded />;
}
