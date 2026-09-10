import type { ForecastModel } from "@t3tools/client-runtime/state/infinitusAccounts";

import { usePrimarySettings } from "../../hooks/useSettings";
import { formatRelativeTimeLabel, formatUpcomingTimestamp } from "../../timestampFormat";

/**
 * The fleet-wide run-rate projection above the sections: when the whole fleet
 * runs out, the order it drains in, and how old the projection is. Estimates,
 * never billing truth.
 */
export function ForecastStrip({ forecast }: { readonly forecast: ForecastModel }) {
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const allDeadAt =
    forecast.allDeadAt === null
      ? null
      : formatUpcomingTimestamp(forecast.allDeadAt, timestampFormat);
  const computed =
    forecast.computedAt === null ? null : formatRelativeTimeLabel(forecast.computedAt);

  return (
    <section className="flex flex-col gap-1 rounded-lg border p-3">
      <p className="text-foreground text-sm">
        {allDeadAt ? `All accounts exhausted by ${allDeadAt}` : "No exhaustion projected"}
      </p>
      {forecast.drainOrder.length > 0 ? (
        <p className="text-muted-foreground text-xs">{forecast.drainOrder.join(" → ")}</p>
      ) : null}
      {computed ? <p className="text-muted-foreground text-xs">computed {computed}</p> : null}
    </section>
  );
}
