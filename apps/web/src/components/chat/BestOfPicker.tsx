import { FlaskConicalIcon } from "lucide-react";
import { useState } from "react";

import { cn } from "../../lib/utils";
import { Button } from "../ui/button";
import { Checkbox } from "../ui/checkbox";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";
import { BEST_OF_MAX, BEST_OF_MIN, type BestOfChip } from "./bestOf.logic";
import { ComposerControl, ComposerControlIcon, type ComposerControlSize } from "./ComposerControl";
import type { ModelEsque } from "./providerIconUtils";

/**
 * Best of N (#269 B): the composer control that picks two to four models of
 * the active provider and starts the draft once per model. Sits beside the
 * model picker; the current model starts checked.
 */
export function BestOfPicker({
  size,
  options,
  currentModel,
  disabled,
  onRun,
}: {
  size: ComposerControlSize;
  options: ReadonlyArray<ModelEsque>;
  currentModel: string;
  disabled?: boolean | undefined;
  onRun: (chips: ReadonlyArray<BestOfChip>) => void;
}) {
  const [open, setOpen] = useState(false);
  const [picked, setPicked] = useState<ReadonlySet<string>>(() => new Set([currentModel]));
  const choices = options.filter((option) => !option.isLegacy && !option.isUnavailable);
  const chips = choices
    .filter((option) => picked.has(option.slug))
    .map((option): BestOfChip => ({ model: option.slug, label: option.shortName ?? option.name }));
  const runnable = chips.length >= BEST_OF_MIN && chips.length <= BEST_OF_MAX;

  return (
    <Popover
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (next) setPicked(new Set([currentModel]));
      }}
    >
      <Tooltip>
        <TooltipTrigger
          render={
            <PopoverTrigger
              render={
                <ComposerControl
                  size={size}
                  className={cn(
                    "shrink-0 whitespace-nowrap",
                    size === "xs" ? undefined : "text-secondary-label hover:text-foreground",
                  )}
                  type="button"
                  disabled={disabled}
                  aria-label="Best of N: start this prompt once per model"
                  data-testid="composer-best-of"
                />
              }
            />
          }
        >
          <ComposerControlIcon icon={FlaskConicalIcon} size={size} />
          <span className="sr-only sm:not-sr-only">Best of</span>
        </TooltipTrigger>
        <TooltipPopup side="top">
          Best of N: start this prompt in {BEST_OF_MIN}–{BEST_OF_MAX} worktrees, one model each,
          then keep the result you like
        </TooltipPopup>
      </Tooltip>
      <PopoverPopup side="top" align="start" className="w-64 p-2">
        <div className="text-muted-foreground px-1 pb-1.5 text-xs">
          Pick {BEST_OF_MIN}–{BEST_OF_MAX} models. Each gets its own worktree; the prompt is sent as
          typed, text only.
        </div>
        <ul className="flex max-h-64 flex-col gap-0.5 overflow-y-auto" data-testid="best-of-models">
          {choices.map((option) => {
            const checked = picked.has(option.slug);
            const full = !checked && picked.size >= BEST_OF_MAX;
            return (
              <li key={option.slug}>
                <label
                  className={cn(
                    "flex cursor-pointer items-center gap-2 rounded-md px-1.5 py-1 text-sm hover:bg-muted/60",
                    full && "cursor-not-allowed opacity-50",
                  )}
                >
                  <Checkbox
                    checked={checked}
                    disabled={full}
                    onCheckedChange={(next) =>
                      setPicked((previous) => {
                        const nextSet = new Set(previous);
                        if (next) nextSet.add(option.slug);
                        else nextSet.delete(option.slug);
                        return nextSet;
                      })
                    }
                  />
                  <span className="truncate">{option.name}</span>
                </label>
              </li>
            );
          })}
        </ul>
        <div className="flex justify-end pt-2">
          <Button
            size="xs"
            type="button"
            disabled={!runnable}
            data-testid="best-of-run"
            onClick={() => {
              setOpen(false);
              onRun(chips);
            }}
          >
            Run {chips.length >= BEST_OF_MIN ? chips.length : "N"}
          </Button>
        </div>
      </PopoverPopup>
    </Popover>
  );
}
