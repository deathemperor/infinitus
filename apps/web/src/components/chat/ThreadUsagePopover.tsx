import type { ThreadUsageRollup } from "@t3tools/contracts";
import { CoinsIcon } from "lucide-react";

import { usePrimarySettings } from "../../hooks/useSettings";
import { formatDayAwareTimestamp } from "../../timestampFormat";
import { Button } from "../ui/button";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";
import {
  threadUsageBadgeAriaLabel,
  threadUsageBadgeLabel,
  threadUsageCostLabel,
  threadUsageRows,
  threadUsageSourceDetail,
  threadUsageSourceLine,
} from "./threadUsage.logic";

/**
 * Fork (#834): the thread-info popover behind a badge in the chat header's
 * action group. The badge reads the thread's estimated cost (or its turn
 * count when no turn carried one); the popover lists turns, tokens by
 * kind, models and the last turn. Drawn only for a thread with a rollup:
 * an empty card on every older thread would be a lying affordance.
 */
export function ThreadUsagePopover({ usage }: { usage: ThreadUsageRollup }) {
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const rows = threadUsageRows(usage);
  const sourceLine = threadUsageSourceLine(usage);
  const sourceDetail = threadUsageSourceDetail(usage);
  return (
    <Popover>
      <PopoverTrigger
        render={
          <Button
            variant="ghost"
            size="xs"
            aria-label={threadUsageBadgeAriaLabel(usage)}
            data-testid="thread-usage-badge"
            className="font-normal text-xs! text-muted-foreground/70 hover:text-foreground/80 active:scale-100"
          />
        }
      >
        <CoinsIcon className="size-3 shrink-0 opacity-70" />
        <span className="tabular-nums">{threadUsageBadgeLabel(usage)}</span>
      </PopoverTrigger>
      <PopoverPopup
        side="bottom"
        align="end"
        className="w-64 max-w-none p-[var(--floating-content-inset)] text-left whitespace-normal"
      >
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between gap-3">
            <div className="font-medium text-muted-foreground text-xs">Thread usage</div>
            <div className="text-secondary-label text-[11px]">estimates</div>
          </div>
          <dl className="flex flex-col gap-1 text-[11px] leading-4">
            {rows.map((row) => (
              <div key={row.label} className="flex items-baseline justify-between gap-3">
                <dt className="text-secondary-label">{row.label}</dt>
                <dd className="truncate font-medium tabular-nums text-secondary-label">
                  {row.value}
                </dd>
              </div>
            ))}
            <div className="flex items-baseline justify-between gap-3">
              <dt className="text-secondary-label">Cost</dt>
              <dd className="font-medium tabular-nums text-secondary-label">
                {threadUsageCostLabel(usage.costUsd)}
              </dd>
            </div>
            <div className="flex items-baseline justify-between gap-3">
              <dt className="text-secondary-label">Last turn</dt>
              <dd className="font-medium tabular-nums text-secondary-label">
                {formatDayAwareTimestamp(usage.lastTurnAt, timestampFormat)}
              </dd>
            </div>
          </dl>
          {sourceLine ? (
            <Tooltip>
              <TooltipTrigger
                render={
                  <div className="cursor-help text-pretty text-secondary-label text-[11px] underline decoration-dotted underline-offset-2" />
                }
              >
                {sourceLine}
              </TooltipTrigger>
              <TooltipPopup side="bottom" className="max-w-64 text-pretty">
                {sourceDetail}
              </TooltipPopup>
            </Tooltip>
          ) : null}
        </div>
      </PopoverPopup>
    </Popover>
  );
}
