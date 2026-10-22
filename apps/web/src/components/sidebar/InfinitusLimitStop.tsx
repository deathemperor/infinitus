import type { EnvironmentId, ThreadId } from "@infinitus/contracts";
import type { InfinitusLimitStop } from "@infinitus/contracts/infinitus";
import type { TimestampFormat } from "@infinitus/contracts/settings";
import { limitStopKey, limitStopLine } from "@infinitus/client-runtime/state/infinitusLimitStops";
import { useAtomValue } from "@effect/atom-react";
import { CircleAlertIcon } from "lucide-react";

import { cn } from "../../lib/utils";
import { infinitusLimitStopsAtom } from "../../state/infinitus";
import { formatShortTimestamp } from "../../timestampFormat";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";

/**
 * Fork (#648): the stop a Claude usage limit parked this thread on, if any.
 * A parked turn is still "running" to the orchestrator; the sidebar row reads
 * "Limited" (`resolveSidebarThreadStatus`'s `limitStopped`) until the account
 * swaps and the turn resumes.
 */
export function useThreadLimitStop(thread: {
  readonly environmentId: EnvironmentId;
  readonly id: ThreadId;
}): InfinitusLimitStop | null {
  return (
    useAtomValue(infinitusLimitStopsAtom).get(limitStopKey(thread.environmentId, thread.id)) ?? null
  );
}

/** The pill's tooltip: the account and the reset, only while the row's
    status is the limit stop's. */
export function limitStopTooltip(
  limitStop: InfinitusLimitStop | null,
  status: string,
  timestampFormat: TimestampFormat,
): string | null {
  return limitStop !== null && status === "limited"
    ? limitStopLine(limitStop, (iso) => formatShortTimestamp(iso, timestampFormat), Date.now())
    : null;
}

/** The "Limited" status pill with the stop's detail as its tooltip; the
    sidebar row renders it in place of its plain status span. */
export function InfinitusLimitStopPill({
  detail,
  label,
  className,
}: {
  detail: string;
  label: string;
  className: string;
}) {
  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <span className={cn("inline-flex items-center gap-1 font-medium", className)}>
            <CircleAlertIcon aria-hidden className="size-4 shrink-0" />
            <span role="status">{label}</span>
          </span>
        }
      />
      <TooltipPopup side="top">{detail}</TooltipPopup>
    </Tooltip>
  );
}
