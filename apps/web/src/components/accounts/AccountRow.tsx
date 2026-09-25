import {
  type AccountAction,
  type AccountResetsModel,
  type AccountRowModel,
  resetHoldText,
  resetsSummary,
  type UsageWindowBar,
} from "@infinitus/client-runtime/state/infinitusAccounts";
import {
  ArrowLeftRightIcon,
  FlameIcon,
  PauseIcon,
  PencilIcon,
  PlayIcon,
  StarIcon,
  TicketIcon,
  Trash2Icon,
  TrendingUpIcon,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";

import { cn } from "../../lib/utils";
import {
  AlertDialog,
  AlertDialogClose,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogPopup,
  AlertDialogTitle,
} from "../ui/alert-dialog";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { Input } from "../ui/input";
import { Popover, PopoverPopup, PopoverTrigger } from "../ui/popover";
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
  autoIgnite: FlameIcon,
  reset: TicketIcon,
  rename: PencilIcon,
  remove: Trash2Icon,
};

/** The tooltip an action's button carries; `prefer` and `autoIgnite` name the side they toggle to. */
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
    case "autoIgnite":
      return row.autoIgnite ? "Stop keeping warm" : "Keep warm (restart its 5h window when cold)";
    case "reset":
      return "Use a banked reset";
    case "rename":
      return "Rename";
    case "remove":
      return "Remove";
  }
}

/**
 * The account's banked limit resets (#1554): a ticket count that opens what
 * the bank holds, what stops the next one, and the redeem button. Spending
 * one is the engine's `reset`, so it asks first like `remove` does.
 */
function ResetsPopover({
  row,
  resets,
  canRedeem,
  busy,
  onRedeem,
}: {
  readonly row: AccountRowModel;
  readonly resets: AccountResetsModel;
  /** The fleet offers `reset` on this row (capability and a bank with something left). */
  readonly canRedeem: boolean;
  readonly busy: boolean;
  readonly onRedeem: () => void;
}) {
  const [open, setOpen] = useState(false);
  const hold = resetHoldText(resets);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger
        render={
          <Button
            size="xs"
            variant="ghost-muted"
            aria-label={`${row.label}: ${resetsSummary(resets)}`}
          />
        }
      >
        <TicketIcon className="size-3" aria-hidden />
        <span className="tabular-nums">{resets.available}</span>
      </PopoverTrigger>
      <PopoverPopup side="bottom" align="start" className="w-72">
        <div className="flex flex-col gap-2 text-xs">
          <span className="font-medium text-foreground tabular-nums">{resetsSummary(resets)}</span>
          {resets.label === null ? null : (
            <span className="text-muted-foreground">{resets.label}</span>
          )}
          {hold === null ? null : <span className="text-muted-foreground">{hold}</span>}
          {canRedeem ? (
            <Button
              size="xs"
              variant="outline"
              className="self-start"
              disabled={busy || hold !== null}
              onClick={() => {
                setOpen(false);
                onRedeem();
              }}
            >
              {busy ? "Using…" : "Use reset"}
            </Button>
          ) : null}
        </div>
      </PopoverPopup>
    </Popover>
  );
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
  onRelogin,
  reloginBusy = false,
}: {
  readonly row: AccountRowModel;
  readonly pendingAction: AccountAction | null;
  readonly failure: string | null;
  readonly onAction: (action: AccountAction, alias?: string) => void;
  /** Starts the fleet's sign-in for this lapsed account; absent when the row
      needs none or the build has no `add` verb. */
  readonly onRelogin?: (() => void) | undefined;
  /** A sign-in is already running (here or in the Mac app), so no second one. */
  readonly reloginBusy?: boolean;
}) {
  const [renaming, setRenaming] = useState(false);
  const [alias, setAlias] = useState(row.label);
  /** `remove` deletes the credential from the engine, so it asks first. */
  const [confirmRemove, setConfirmRemove] = useState(false);
  /** `reset` spends a banked reset the provider will not give back. */
  const [confirmReset, setConfirmReset] = useState(false);
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
          <StarIcon className="size-3 fill-current text-warning" aria-label="Preferred" />
        ) : null}
        {row.autoIgnite ? (
          <FlameIcon className="size-3 fill-current text-warning" aria-label="Kept warm" />
        ) : null}
        {row.plan === null ? null : (
          <span className="text-muted-foreground text-xs">{row.plan}</span>
        )}
        {row.resets === null ? null : (
          <ResetsPopover
            row={row}
            resets={row.resets}
            canRedeem={row.actions.includes("reset")}
            busy={busy}
            onRedeem={() => setConfirmReset(true)}
          />
        )}
        <span className="ms-auto flex items-center gap-2">
          {freshness === null ? null : (
            <span className="text-muted-foreground text-xs">{freshness}</span>
          )}
          {onRelogin === undefined ? null : (
            <Button
              size="xs"
              variant="outline"
              disabled={busy || reloginBusy}
              aria-label={`Sign in again as ${row.label}`}
              onClick={onRelogin}
            >
              Sign in again
            </Button>
          )}
          {row.actions.map((action) => {
            // The ticket beside the plan is its button; no second one here.
            if (action === "reset") return null;
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
                        else if (action === "remove") setConfirmRemove(true);
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
                        action === "autoIgnite" && row.autoIgnite && "fill-current text-warning",
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

      {row.scoped.length > 0 ? <WindowGrid windows={row.scoped} /> : null}

      {failure === null ? null : <p className="text-destructive text-xs">{failure}</p>}

      <AlertDialog open={confirmRemove} onOpenChange={setConfirmRemove}>
        <AlertDialogPopup>
          <AlertDialogHeader>
            <AlertDialogTitle>Remove {row.label}?</AlertDialogTitle>
            <AlertDialogDescription>
              Deletes {row.email}'s credential from the engine. Signing in again adds it back.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogClose render={<Button variant="outline" />}>Cancel</AlertDialogClose>
            <Button
              variant="destructive"
              aria-label={`Confirm removing ${row.label}`}
              onClick={() => {
                setConfirmRemove(false);
                onAction("remove");
              }}
            >
              Remove
            </Button>
          </AlertDialogFooter>
        </AlertDialogPopup>
      </AlertDialog>
      <AlertDialog open={confirmReset} onOpenChange={setConfirmReset}>
        <AlertDialogPopup>
          <AlertDialogHeader>
            <AlertDialogTitle>Use a reset on {row.label}?</AlertDialogTitle>
            <AlertDialogDescription>
              This spends one of the account&apos;s banked limit resets. The provider does not give
              it back.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogClose render={<Button variant="outline" />}>Cancel</AlertDialogClose>
            <Button
              onClick={() => {
                setConfirmReset(false);
                onAction("reset");
              }}
            >
              Use reset
            </Button>
          </AlertDialogFooter>
        </AlertDialogPopup>
      </AlertDialog>
    </div>
  );
}
