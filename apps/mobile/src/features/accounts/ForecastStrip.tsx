import type { ForecastModel } from "@t3tools/client-runtime/state/infinitusAccounts";
import { View } from "react-native";

import { AppText as Text } from "../../components/AppText";

function clock(iso: string): string {
  const date = new Date(iso);
  return Number.isNaN(date.getTime())
    ? iso
    : date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

/** The fleet-wide projection: when every account runs out at the current
    pace, and the order they drain in. Nothing to say when the Mac has no
    forecast yet. */
export function ForecastStrip(props: { readonly forecast: ForecastModel }) {
  const { forecast } = props;
  if (forecast.allDeadAt === null && forecast.drainOrder.length === 0) return null;
  return (
    <View className="gap-1.5 rounded-[24px] border-continuous bg-card p-4">
      <Text className="text-sm font-t3-medium text-foreground">Forecast</Text>
      {forecast.allDeadAt ? (
        <Text className="text-sm text-foreground-muted">
          All accounts limited by {clock(forecast.allDeadAt)} at the current pace.
        </Text>
      ) : (
        <Text className="text-sm text-foreground-muted">
          Some account stays within its limits at the current pace.
        </Text>
      )}
      {forecast.drainOrder.length > 0 ? (
        <Text className="text-xs text-foreground-tertiary">
          Drains {forecast.drainOrder.join(", then ")}.
        </Text>
      ) : null}
      {forecast.computedAt ? (
        <Text className="text-2xs text-foreground-tertiary">
          Computed {clock(forecast.computedAt)}
        </Text>
      ) : null}
    </View>
  );
}
