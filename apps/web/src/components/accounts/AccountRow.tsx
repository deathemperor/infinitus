import type {
  AccountAction,
  AccountRowModel,
  UsageWindowBar,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import {
  ArrowLeftRightIcon,
  ChevronDownIcon,
  ChevronRightIcon,
  PauseIcon,
  PencilIcon,
  PlayIcon,
  StarIcon,
  TrendingUpIcon,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";

import { cn } from "../../lib/utils";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { Input } from "../ui/input";
import { Spinner } from "../ui/spinner";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";

/**
 * One window as a bar filled to the share of quota spent, reading like the
 * bars on Usage → Limits. The countdown is the engine's own string, so nothing
 * here ticks.
 */
function UsageBar({ window }: { readonly window: UsageWindowBar }) {
  const summary = `${window.name}: ${window.pct}% used${
    window.countdown === null ? "" : `, resets in ${window.countdown}`
  }${window.aheadOfPace === true ? ", ahead of pace" : ""}`;
  return (
    <>
      <span className="flex min-w-0 items-center gap-2 text-xs">
        <span className="truncate text-muted-foreground">{window.name}</span>
        <span className="ms-auto shrink-0 font-medium text-foreground tabular-nums">
          {window.pct}% used
        </span>
      </span>
      <span
        role="img"
        aria-label={summary}
        className="relative block h-6 cursor-default rounded-full"
      >
        <span className="absolute inset-x-0 inset-y-1.5 rounded-full bg-muted" />
        {window.pct > 0 ? (
          <span
            className="absolute inset-y-1.5 left-0 rounded-full bg-foreground/60"
            style={{ width: `${window.pct}%` }}
          />
        ) : null}
      </span>
      <span className="flex items-center gap-2 whitespace-nowrap text-muted-foreground text-xs tabular-nums">
        {window.aheadOfPace === true ? (
          <TrendingUpIcon className="size-3.5" aria-label="Ahead of pace" />
        ) : null}
        <span className="ms-auto shrink-0">
          {window.countdown === null ? "" : `resets in ${window.countdown}`}
        </span>
      </span>
    </>
  );
}

function WindowGrid({ windows }: { readonly windows: ReadonlyArray<UsageWindowBar> }) {
  return (
    <div className="grid grid-cols-[minmax(0,9rem)_minmax(3rem,1fr)_auto] items-center gap-x-3 gap-y-0.5">
      {windows.map((window) => (
        <UsageBar key={window.name} window={window} />
      ))}
    </div>
  );
}

const ACTION_ICON: Record<AccountAction, typeof StarIcon> = {
  switch: ArrowLeftRightIcon,
  hold: PauseIcon,
  unhold: PlayIcon,
  prefer: StarIcon,
  rename: PencilIcon,
};

/** The tooltip an action's button carries; `prefer` names the side it toggles to. */
function actionLabel(row: AccountRowModel, action: AccountAction): string {
  switch (action) {
    case "switch":
      return "Switch";
    case "hold":
      return "Hold";
    case "unhold":
      return "Unhold";
    case "prefer":
      return row.preferred ? "Stop preferring" : "Prefer";
    case "rename":
      return "Rename";
  }
}

/**
 * One account: who it is, what the engine is doing with it, its windows, and
 * the actions the fleet's capabilities allow. Everything shown comes from the
 * row model; the page owns the command in flight and the last failure.
 */
export function AccountRow({
  row,
  pendingAction,
  failure,
  onAction,
}: {
  readonly row: AccountRowModel;
  readonly pendingAction: AccountAction | null;
  readonly failure: string | null;
  readonly onAction: (action: AccountAction, alias?: string) => void;
}) {
  const [renaming, setRenaming] = useState(false);
  const [alias, setAlias] = useState(row.label);
  const [scopedOpen, setScopedOpen] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const busy = pendingAction !== null;

  useEffect(() => {
    if (renaming) inputRef.current?.focus();
  }, [renaming]);

  const startRename = () => {
    setAlias(row.label);
    setRenaming(true);
  };
  const submitRename = () => {
    const next = alias.trim();
    if (next === "") return;
    setRenaming(false);
    onAction("rename", next);
  };

  // The held badge already says why there is no reading, so the row does not
  // repeat it as freshness.
  const freshness = row.held && row.freshness === "usage unavailable" ? null : row.freshness;

  return (
    <div className="flex flex-col gap-1.5 border-border/60 border-t py-3 first:border-t-0">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        {renaming ? (
          <Input
            ref={inputRef}
            size="compact"
            aria-label={`Rename ${row.label}`}
            value={alias}
            className="w-48"
            onChange={(event) => setAlias(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") submitRename();
              if (event.key === "Escape") setRenaming(false);
            }}
          />
        ) : (
          <span className={cn("min-w-0 truncate text-sm", row.active && "font-semibold")}>
            {row.label}
          </span>
        )}
        {row.active ? (
          <Badge size="sm" variant="success">
            Active
          </Badge>
        ) : null}
        {row.next ? (
          <Badge size="sm" variant="outline">
            Next
          </Badge>
        ) : null}
        {row.held ? (
          <Badge size="sm" variant="warning">
            Held
          </Badge>
        ) : null}
        {row.preferred ? (
          <StarIcon className="size-3 fill-current text-yellow-500" aria-label="Preferred" />
        ) : null}
        {row.plan === null ? null : (
          <span className="text-muted-foreground text-xs">{row.plan}</span>
        )}
        <span className="ms-auto flex items-center gap-2">
          {freshness === null ? null : (
            <span className="text-muted-foreground text-xs">{freshness}</span>
          )}
          {row.actions.map((action) => {
            const Icon = ACTION_ICON[action];
            const label = actionLabel(row, action);
            return (
              <Tooltip key={action}>
                <TooltipTrigger
                  render={
                    <Button
                      size="icon-xs"
                      variant="ghost"
                      disabled={busy}
                      aria-label={`${label} ${row.label}`}
                      onClick={() => {
                        if (action === "rename") startRename();
                        else onAction(action);
                      }}
                    />
                  }
                >
                  {pendingAction === action ? (
                    <Spinner className="size-3" />
                  ) : (
                    <Icon
                      className={cn(
                        "size-3",
                        action === "prefer" && row.preferred && "fill-current",
                      )}
                    />
                  )}
                </TooltipTrigger>
                <TooltipPopup side="top">{label}</TooltipPopup>
              </Tooltip>
            );
          })}
        </span>
      </div>

      {row.windows.length > 0 ? <WindowGrid windows={row.windows} /> : null}

      {row.scoped.length > 0 ? (
        <div className="flex flex-col gap-1">
          <Button
            size="xs"
            variant="ghost"
            className="self-start text-muted-foreground"
            aria-expanded={scopedOpen}
            onClick={() => setScopedOpen((open) => !open)}
          >
            {scopedOpen ? (
              <ChevronDownIcon className="size-3" aria-hidden />
            ) : (
              <ChevronRightIcon className="size-3" aria-hidden />
            )}
            {row.scoped.length} model {row.scoped.length === 1 ? "window" : "windows"}
          </Button>
          {scopedOpen ? <WindowGrid windows={row.scoped} /> : null}
        </div>
      ) : null}

      {failure === null ? null : <p className="text-destructive text-xs">{failure}</p>}
    </div>
  );
}
