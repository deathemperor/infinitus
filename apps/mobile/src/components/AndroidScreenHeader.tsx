import { useState, type ReactNode } from "react";
import { View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

<<<<<<< HEAD
import { AndroidAnchoredMenu, type AndroidAnchoredMenuProps } from "./AndroidAnchoredMenu";
import { SymbolView, type AppSymbolName } from "./AppSymbol";
=======
import type { AppSymbolName } from "./AppSymbol";
>>>>>>> upstream-sync-d4d5d12e8-upstream-renamed
import { AppText as Text } from "./AppText";
import { cn } from "../lib/cn";
import { MaterialIconButton } from "./MaterialIconButton";
import { AndroidAnchoredMenu } from "./AndroidAnchoredMenu";
import { useScaledTextRole } from "../features/settings/appearance/useScaledTextRole";
import { useMaterialToolbarHeight } from "./useMaterialToolbarHeight";

export interface AndroidHeaderAction {
  readonly accessibilityLabel: string;
  readonly icon: AppSymbolName;
  readonly onPress: () => void;
  readonly disabled?: boolean;
<<<<<<< HEAD
  /** Infinitus (fork, #269 F): an action whose tap opens an anchored menu of
      these choices instead of running `onPress` — the Android form of an
      iOS header menu item, with no cap on the number of choices (an
      `Alert` shows at most three buttons). */
  readonly menu?: Pick<AndroidAnchoredMenuProps, "actions" | "title" | "onPressAction">;
=======
  readonly selected?: boolean;
>>>>>>> upstream-sync-d4d5d12e8-upstream-renamed
}

export function AndroidHeaderIconButton(props: {
  readonly accessibilityLabel: string;
  readonly icon: AppSymbolName;
  readonly onPress?: () => void;
  readonly disabled?: boolean;
  readonly selected?: boolean;
}) {
  return <MaterialIconButton {...props} variant={props.selected ? "tonal" : "standard"} />;
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
            onPress={props.onBack}
          />
        ) : null}

        {props.leading}

        <View className={cn("min-w-0 flex-1", !props.onBack && "pl-1")}>
<<<<<<< HEAD
          <Text numberOfLines={1} className="text-lg font-infinitus-bold text-foreground">
=======
          <Text numberOfLines={1} style={titleTypography} className="text-foreground">
>>>>>>> upstream-sync-d4d5d12e8-upstream-renamed
            {props.title}
          </Text>
          {props.subtitle ? (
            <Text
              numberOfLines={1}
<<<<<<< HEAD
=======
              style={subtitleTypography}
>>>>>>> upstream-sync-d4d5d12e8-upstream-renamed
              className="mt-px text-[13px] font-infinitus-medium text-foreground-muted"
            >
              {props.subtitle}
            </Text>
          ) : null}
        </View>

<<<<<<< HEAD
        {props.actions?.map((action) =>
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
              icon={action.icon}
              onPress={action.onPress}
            />
          ),
        )}
=======
        {visibleActions.map((action) => (
          <AndroidHeaderIconButton
            key={action.accessibilityLabel}
            accessibilityLabel={action.accessibilityLabel}
            disabled={action.disabled}
            selected={action.selected}
            icon={action.icon}
            onPress={action.onPress}
          />
        ))}
        {overflowActions.length > 0 ? (
          <AndroidAnchoredMenu
            actions={overflowActions.map((action, index) => ({
              id: String(index),
              title: action.accessibilityLabel,
              attributes: {
                disabled: Boolean(action.disabled),
                state: action.selected ? "on" : undefined,
              },
            }))}
            onPressAction={({ nativeEvent }) =>
              overflowActions[Number(nativeEvent.event)]?.onPress()
            }
          >
            {(open) => (
              <MaterialIconButton
                accessibilityLabel="More actions"
                icon="ellipsis"
                onPress={open}
              />
            )}
          </AndroidAnchoredMenu>
        ) : null}
>>>>>>> upstream-sync-d4d5d12e8-upstream-renamed
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
