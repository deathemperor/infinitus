import type { ThreadUsageRollup } from "@infinitus/contracts";
import { CoinsIcon } from "lucide-react";

import { usePrimarySettings } from "../../hooks/useSettings";
import { formatDayAwareTimestamp } from "../../timestampFormat";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";
import { ComposerControl } from "./ComposerControl";
import {
  threadUsageBadgeAriaLabel,
  threadUsageBadgeLabel,
  threadUsageCostLabel,
  threadUsageRowGroups,
  threadUsageSourceDetail,
  threadUsageSourceLine,
  threadUsageUnreportedLine,
} from "./threadUsage.logic";

/**
 * Fork (#834): the thread-info popover behind a badge in the chat header's
 * action group. The badge reads the thread's estimated cost (or its turn
 * count when no turn carried one); the popover leads with that cost and
 * lists what the thread did, the tokens by kind, the models and the last
 * turn under it. Drawn only for a thread with a rollup: an empty card on
 * every older thread would be a lying affordance.
 */
export function ThreadUsagePopover({ usage }: { usage: ThreadUsageRollup }) {
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const [work = [], tokens = [], models = []] = threadUsageRowGroups(usage);
  const sourceLine = threadUsageSourceLine(usage);
  const sourceDetail = threadUsageSourceDetail(usage);
  const unreportedLine = threadUsageUnreportedLine(usage);
  // The cost is the headline; without one, why it is missing takes its place.
  const missingCostLine =
    unreportedLine ?? (usage.costUsd === null ? threadUsageCostLabel(null) : null);
  const sections = [
    work,
    tokens,
    [
      ...models,
      { label: "Last turn", value: formatDayAwareTimestamp(usage.lastTurnAt, timestampFormat) },
    ],
  ].filter((section) => section.length > 0);
  return (
    <Popover>
      <PopoverTrigger
        render={
          <ComposerControl
            size="xs"
            aria-label={threadUsageBadgeAriaLabel(usage)}
            data-testid="thread-usage-badge"
            className="active:scale-100"
          />
        }
      >
        <CoinsIcon className="size-3 shrink-0 opacity-70" />
        <span className="tabular-nums">{threadUsageBadgeLabel(usage)}</span>
      </PopoverTrigger>
      <PopoverPopup
        side="bottom"
        align="end"
        padding="compact"
        className="w-72 max-w-none text-left whitespace-normal"
      >
        <div className="flex flex-col gap-2.5">
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="font-medium text-muted-foreground text-xs">Thread usage</div>
              {missingCostLine ? (
                <div className="mt-1 text-pretty text-2xs text-secondary-label leading-4">
                  {missingCostLine}
                </div>
              ) : (
                <div className="mt-0.5 font-semibold text-base text-foreground tabular-nums leading-5">
                  {threadUsageCostLabel(usage.costUsd)}
                </div>
              )}
            </div>
            <div className="shrink-0 text-2xs text-secondary-label">estimates</div>
          </div>
          <dl className="flex flex-col gap-2 text-2xs leading-4">
            {sections.map((section, index) => (
              <div
                key={section[0]?.label ?? index}
                className={
                  index === 0
                    ? "flex flex-col gap-1"
                    : "flex flex-col gap-1 border-border/60 border-t pt-2"
                }
              >
                {section.map((row) => (
                  <div key={row.label} className="flex items-baseline justify-between gap-3">
                    <dt className="shrink-0 text-secondary-label">{row.label}</dt>
                    <dd className="min-w-0 break-words text-right font-medium text-foreground/90 tabular-nums">
                      {row.value}
                    </dd>
                  </div>
                ))}
              </div>
            ))}
          </dl>
          {sourceLine ? (
            <Tooltip>
              <TooltipTrigger
                render={
                  <div className="cursor-help text-pretty text-secondary-label text-2xs underline decoration-dotted underline-offset-2" />
                }
              >
                {sourceLine}
              </TooltipTrigger>
              <TooltipPopup side="bottom" className="max-w-64">
                {sourceDetail}
              </TooltipPopup>
            </Tooltip>
          ) : null}
        </div>
      </PopoverPopup>
    </Popover>
  );
}
