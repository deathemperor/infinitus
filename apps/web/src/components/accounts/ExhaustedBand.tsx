import type { ExhaustedBandModel } from "@t3tools/client-runtime/state/infinitusExhausted";

import { usePrimarySettings } from "../../hooks/useSettings";
import { useNowMinute } from "../../hooks/useNowMinute";
import { formatUpcomingTimestamp } from "../../timestampFormat";

/** The compact all-accounts-exhausted band a fleet section carries when every
    unheld account is at a limit (#659): the pop-out's reviver band, in the
    fork. Re-reads on the shared minute clock so "today" stays right. */
export function ExhaustedBand({ band }: { readonly band: ExhaustedBandModel }) {
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const minute = useNowMinute();
  const revival =
    band.revivalAt === null
      ? null
      : formatUpcomingTimestamp(band.revivalAt, timestampFormat, Date.parse(minute));
  const who = band.revivesFirst === null ? "" : ` (${band.revivesFirst})`;
  return (
    <p role="status" className="rounded-md bg-warning/16 px-2 py-1 text-warning-foreground text-xs">
      {revival === null || revival === ""
        ? "All accounts exhausted"
        : `All accounts exhausted · next revival ${revival}${who}`}
    </p>
  );
}
