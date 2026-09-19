import Constants from "expo-constants";
import { Image } from "expo-image";
import { View } from "react-native";

import { AppText as Text } from "./AppText";
import { resolveMobileBrandMarkVariant, resolveMobileStageLabel } from "../lib/mobileBranding";
import { PRODUCT_NAME } from "@infinitus/shared/productName";

const appVariant = Constants.expoConfig?.extra?.appVariant;
const BRAND_MARK_SOURCES = {
  infinitus: require("../../assets/infinitus-ios-1024.png"),
  development: require("../../../../assets/dev/blueprint-ios-1024.png"),
  preview: require("../../../../assets/nightly/nightly-ios-1024.png"),
  prod: require("../../../../assets/prod/black-ios-1024.png"),
} as const;
const BRAND_MARK_SOURCE = BRAND_MARK_SOURCES[resolveMobileBrandMarkVariant(appVariant)];
const DEFAULT_STAGE_LABEL = resolveMobileStageLabel(appVariant);

export function BrandMark(props: { readonly compact?: boolean; readonly stageLabel?: string }) {
  const compact = props.compact ?? false;
  const iconSize = compact ? 32 : 44;
  const stageLabel = props.stageLabel ?? DEFAULT_STAGE_LABEL;

  return (
    <View className="flex-row items-center gap-3">
      <Image
        source={BRAND_MARK_SOURCE}
        accessibilityIgnoresInvertColors
        style={{
          width: iconSize,
          height: iconSize,
          borderRadius: compact ? 10 : 14,
        }}
      />
      <View className="gap-1">
        <View className="flex-row items-center gap-2">
          <Text className="text-lg font-infinitus-bold tracking-[-0.4px] text-foreground">
<<<<<<< HEAD
            {PRODUCT_NAME}
=======
            T3 Code
>>>>>>> upstream-sync-803f94e78-upstream-renamed
          </Text>
          <View className="rounded-full bg-subtle px-2 py-1">
            <Text className="text-3xs font-infinitus-bold tracking-[1.1px] uppercase text-foreground-muted">
              {stageLabel}
            </Text>
          </View>
        </View>
        {!compact ? (
          <Text className="text-xs font-medium text-foreground-muted">
            Mobile control surface for your live coding environments
          </Text>
        ) : null}
      </View>
    </View>
  );
}
