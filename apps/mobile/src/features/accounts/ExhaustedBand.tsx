import type { ExhaustedBandModel } from "@t3tools/client-runtime/state/infinitusExhausted";
import { View } from "react-native";

import { AppText as Text } from "../../components/AppText";
import { exhaustedCopy } from "./accountsRoute.logic";

/** The compact all-accounts-exhausted band a fleet card opens with when every
    unheld account is at a limit (#706): web's band (#662), on the phone. */
export function ExhaustedBand(props: {
  readonly band: ExhaustedBandModel;
  readonly nowMs: number;
}) {
  return (
    <View accessibilityRole="alert" className="bg-danger px-4 py-2">
      <Text className="text-xs font-t3-medium text-danger-foreground">
        {exhaustedCopy(props.band, props.nowMs)}
      </Text>
    </View>
  );
}
