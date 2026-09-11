import { BABYSIT_MAX_ROUNDS, type ThreadBabysit } from "@t3tools/contracts";
import { BabyIcon } from "lucide-react";

import { Button } from "./ui/button";
import { cn } from "../lib/utils";
import { Tooltip, TooltipPopup, TooltipTrigger } from "./ui/tooltip";

/**
 * Fork (#269 A): the composer's babysit toggle. While on, the server queues
 * a fix round whenever the thread's open pull request conflicts, its checks
 * fail or a review requests changes (`InfinitusBabysitLive`), up to
 * `BABYSIT_MAX_ROUNDS`; the label counts the rounds taken.
 */
export function ThreadBabysitToggle({
  babysit,
  onToggle,
}: {
  babysit: ThreadBabysit | null;
  onToggle: (on: boolean) => void;
}) {
  const on = babysit !== null;
  const label = on ? `Babysit ${babysit.rounds}/${BABYSIT_MAX_ROUNDS}` : "Babysit";
  const tooltip = on
    ? `Babysitting: a fix round is queued whenever the pull request conflicts, fails its checks or gets changes requested (${babysit.rounds} of ${BABYSIT_MAX_ROUNDS} rounds used). Click to stop.`
    : "Babysit the pull request: queue a fix round whenever it conflicts, fails its checks or gets changes requested.";
  return (
    <Tooltip>
      <TooltipTrigger
        render={
          <Button
            variant="ghost"
            size="xs"
            aria-pressed={on}
            aria-label={tooltip}
            data-testid="composer-babysit-toggle"
            className={cn(
              "font-normal text-xs! active:scale-100",
              on ? "text-foreground/80" : "text-muted-foreground/70 hover:text-foreground/80",
            )}
            onPointerDown={(event) => event.stopPropagation()}
            onClick={(event) => {
              event.preventDefault();
              event.stopPropagation();
              onToggle(!on);
            }}
          />
        }
      >
        <BabyIcon className="size-3 shrink-0 opacity-70" />
        <span className="tabular-nums">{label}</span>
      </TooltipTrigger>
      <TooltipPopup side="top">{tooltip}</TooltipPopup>
    </Tooltip>
  );
}
