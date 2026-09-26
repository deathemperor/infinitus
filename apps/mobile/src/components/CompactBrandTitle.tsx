import Constants from "expo-constants";
import type { NativeStackNavigationOptions } from "@react-navigation/native-stack";
import { Platform, View } from "react-native";

import { AppText as Text } from "./AppText";
import { IPAD_HOME_TITLE_OFFSET } from "../lib/layoutMetrics";
import { resolveMobileStageLabel } from "../lib/mobileBranding";
<<<<<<< HEAD
import { PRODUCT_NAME } from "@infinitus/shared/productName";
=======
import { useAndroidControlSizing } from "./useAndroidControlSizing";
>>>>>>> upstream-sync-a21b42cec-upstream-renamed

/**
 * Horizontal correction applied to content rendered in the brand title slot,
 * shared with the connection-status swap so both align identically.
 */
export function brandTitleOffset(): number {
  if (Platform.OS !== "ios") return 0;
  return Platform.isPad ? IPAD_HOME_TITLE_OFFSET : 0;
}

/**
 * Compact brand lockup sized for native navigation bars.
 */
export function CompactBrandTitle(
  props: {
    readonly allowFontScaling?: boolean;
  } = {},
) {
  const stageLabel = resolveMobileStageLabel(Constants.expoConfig?.extra?.appVariant);
  const titleOffset = brandTitleOffset();
  const { scale } = useAndroidControlSizing();

  return (
    <View
      aria-level={1}
      accessibilityLabel={`${PRODUCT_NAME}, Threads`}
      accessible
      role="heading"
      className="flex-row items-center gap-1.5"
      style={[{ marginLeft: titleOffset }, Platform.OS === "android" && { gap: 5.25 * scale }]}
    >
<<<<<<< HEAD
      <Text
        allowFontScaling={props.allowFontScaling}
        className="font-infinitus-medium text-[21px] tracking-[-0.5px] text-foreground"
=======
      <InfinitusWordmark colorClassName="accent-icon" height={Math.round(15 * scale)} />
      <Text
        allowFontScaling={props.allowFontScaling}
        className="font-infinitus-medium text-foreground-muted"
        style={{ fontSize: 21 * scale, letterSpacing: -0.5 * scale }}
>>>>>>> upstream-sync-a21b42cec-upstream-renamed
      >
        {PRODUCT_NAME}
      </Text>
      <View
        className="rounded-full bg-subtle px-1.5 py-0.5"
        style={
          Platform.OS === "android"
            ? { paddingHorizontal: 5.25 * scale, paddingVertical: 1.75 * scale }
            : undefined
        }
      >
        <Text
          allowFontScaling={props.allowFontScaling}
          className="font-infinitus-bold text-foreground-muted uppercase"
          style={{ fontSize: 9 * scale, letterSpacing: 0.9 * scale }}
        >
          {stageLabel}
        </Text>
      </View>
    </View>
  );
}

export function renderCompactBrandTitle() {
  return <CompactBrandTitle allowFontScaling={Platform.OS === "ios"} />;
}

export function getCompactBrandHeaderOptions(
  fallbackTitleStyle?: NativeStackNavigationOptions["headerTitleStyle"],
): NativeStackNavigationOptions {
  return {
    headerTitle: renderCompactBrandTitle,
    headerTitleStyle: fallbackTitleStyle,
    title: "Threads",
    unstable_headerLeftItems: undefined,
  };
}
