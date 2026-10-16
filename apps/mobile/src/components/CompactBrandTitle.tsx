import { NATIVE_WORKSPACE_COLUMNS_SUPPORTED } from "../native/NativeWorkspaceColumns";
import Constants from "expo-constants";
import type { NativeStackNavigationOptions } from "@react-navigation/native-stack";
import { Platform, View } from "react-native";

<<<<<<< HEAD
import { AppText as Text } from "./AppText";
import { IPAD_HOME_TITLE_OFFSET } from "../lib/layoutMetrics";
import { resolveMobileStageLabel } from "../lib/mobileBranding";
import { PRODUCT_NAME } from "@infinitus/shared/productName";
import { useAndroidControlSizing } from "./useAndroidControlSizing";
=======
import { AppText as Text } from "./ui/AppText";
import { InfinitusWordmark } from "./InfinitusWordmark";
import { IPAD_HOME_TITLE_OFFSET } from "../lib/layoutMetrics";
import { resolveMobileStageLabel } from "../lib/mobileBranding";
import { useAndroidControlSizing } from "./ui/useAndroidControlSizing";
>>>>>>> upstream-sync-e3b35d1b2-upstream-renamed

export function brandTitleOffset(): number {
  if (Platform.OS !== "ios") return 0;
  return Platform.isPad && !NATIVE_WORKSPACE_COLUMNS_SUPPORTED ? IPAD_HOME_TITLE_OFFSET : 0;
}

export function CompactBrandTitle(
  props: {
    readonly allowFontScaling?: boolean;
    readonly accessibilityLabel?: string;
  } = {},
) {
  const stageLabel = resolveMobileStageLabel(Constants.expoConfig?.extra?.appVariant);
  const titleOffset = brandTitleOffset();
  const { scale } = useAndroidControlSizing();

  return (
    <View
      aria-level={1}
      accessibilityLabel={props.accessibilityLabel ?? `${PRODUCT_NAME}, Threads`}
      accessible
      role="heading"
      className="flex-row items-center gap-1.5"
      style={[{ marginLeft: titleOffset }, Platform.OS === "android" && { gap: 5.25 * scale }]}
    >
      <Text
        allowFontScaling={props.allowFontScaling}
        className="font-infinitus-medium text-foreground"
        style={{ fontSize: 21 * scale, letterSpacing: -0.5 * scale }}
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
