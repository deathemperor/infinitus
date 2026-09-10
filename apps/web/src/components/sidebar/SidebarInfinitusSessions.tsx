import { useAtomValue } from "@effect/atom-react";
import {
  SESSION_PERMISSION_MODES,
  sessionModeCommandArgs,
  type SessionPermissionMode,
  type SessionRowModel,
} from "@t3tools/client-runtime/state/infinitusSessions";
import * as Cause from "effect/Cause";
import * as Schema from "effect/Schema";
import { ChevronRightIcon } from "lucide-react";
import { memo, useMemo, useState } from "react";

import { useLocalStorage } from "../../hooks/useLocalStorage";
import { usePrimaryEnvironmentId } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { useEnvironmentQuery } from "../../state/query";
import { primaryServerConfigAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import { Collapsible, CollapsiblePanel, CollapsibleTrigger } from "../ui/collapsible";
import {
  Menu,
  MenuGroup,
  MenuGroupLabel,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuTrigger,
} from "../ui/menu";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";
import { cn } from "../../lib/utils";
import { sessionCommandErrorMessage, sidebarSessionsView } from "./sidebarInfinitusSessions.logic";

const OPEN_KEY = "infinitus.sidebarSessionsOpen";

const STATE_DOT: Record<SessionRowModel["state"], string> = {
  waiting: "bg-warning",
  working: "bg-primary",
  idle: "bg-muted-foreground/50",
  shell: "bg-muted-foreground/50",
  unknown: "bg-muted-foreground/30",
};

/**
 * The footer's Sessions group: the Claude Code sessions the Mac tracks, waiting
 * ones first. A row's only action is the manifest's `session-mode` verb — the
 * one per-session write the app exposes that is neither stdin text nor
 * destructive — so a click opens its permission-mode radio.
 */
export const SidebarInfinitusSessions = memo(function SidebarInfinitusSessions() {
  const environmentId = usePrimaryEnvironmentId();
  const capability = useAtomValue(primaryServerConfigAtom)?.environment.capabilities.infinitus;
  const snapshotQuery = useEnvironmentQuery(
    capability === true && environmentId !== null
      ? infinitusEnvironment.snapshot({ environmentId, input: {} })
      : null,
  );
  const snapshot = snapshotQuery.data;
  const view = useMemo(() => sidebarSessionsView({ capability, snapshot }), [capability, snapshot]);
  const [open, setOpen] = useLocalStorage(OPEN_KEY, true, Schema.Boolean);
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [failure, setFailure] = useState<{ pid: number; message: string } | null>(null);

  if (view === null || environmentId === null) return null;

  const setMode = async (row: SessionRowModel, mode: SessionPermissionMode) => {
    if (mode === row.permissionMode) return;
    const { command, args } = sessionModeCommandArgs(row, mode);
    const result = await runCommand({
      environmentId,
      input: { command, args: [...args], options: {} },
    });
    setFailure(
      result._tag === "Success"
        ? null
        : { pid: row.pid, message: sessionCommandErrorMessage(Cause.squash(result.cause)) },
    );
  };

  return (
    <Collapsible open={open} onOpenChange={setOpen} className="flex flex-col">
      <CollapsibleTrigger className="flex h-7 w-full items-center gap-1.5 rounded-lg px-2 text-left text-muted-foreground text-xs font-medium hover:bg-sidebar-row-hover">
        <ChevronRightIcon
          className={cn("size-3.5 shrink-0 transition-transform", open && "rotate-90")}
          aria-hidden
        />
        <span className="min-w-0 flex-1 truncate">Sessions</span>
        {view.waitingCount > 0 ? (
          <span className="rounded-full bg-warning px-1.5 text-[10px] font-semibold text-warning-foreground tabular-nums">
            {view.waitingCount}
          </span>
        ) : null}
        <span className="text-[10px] tabular-nums">{view.rows.length}</span>
      </CollapsibleTrigger>
      <CollapsiblePanel>
        <ul className="flex max-h-48 flex-col gap-0.5 overflow-y-auto py-0.5">
          {view.rows.map((row) => (
            <li key={row.pid} className="flex flex-col">
              <SessionRow row={row} canSetMode={view.canSetMode} onSetMode={setMode} />
              {failure?.pid === row.pid ? (
                <span className="px-2 pb-1 text-[11px] text-destructive">{failure.message}</span>
              ) : null}
            </li>
          ))}
        </ul>
      </CollapsiblePanel>
    </Collapsible>
  );
});

function SessionRow({
  row,
  canSetMode,
  onSetMode,
}: {
  row: SessionRowModel;
  canSetMode: boolean;
  onSetMode: (row: SessionRowModel, mode: SessionPermissionMode) => Promise<void>;
}) {
  const label = `${row.title} · ${row.stateLabel}`;
  const body = (
    <>
      <span className={cn("size-2 shrink-0 rounded-full", STATE_DOT[row.state])} aria-hidden />
      <span className="min-w-0 flex-1 truncate text-sidebar-foreground">{row.title}</span>
      <span className="max-w-[45%] shrink-0 truncate text-muted-foreground">
        {row.title === row.folder ? row.stateLabel : row.folder}
      </span>
    </>
  );
  const className =
    "flex h-6 w-full items-center gap-2 rounded-md px-2 text-left text-xs hover:bg-sidebar-row-hover";

  if (!canSetMode) {
    return (
      <Tooltip>
        <TooltipTrigger render={<div className={className}>{body}</div>} />
        <TooltipPopup side="top">{`${label} · ${row.cwd}`}</TooltipPopup>
      </Tooltip>
    );
  }

  return (
    <Menu>
      <Tooltip>
        <TooltipTrigger
          render={
            <MenuTrigger
              render={
                <button type="button" aria-label={label} className={className}>
                  {body}
                </button>
              }
            />
          }
        />
        <TooltipPopup side="top">{`${label} · ${row.cwd}`}</TooltipPopup>
      </Tooltip>
      <MenuPopup align="start" side="top" className="w-56">
        <MenuGroup>
          <MenuGroupLabel>Permission mode</MenuGroupLabel>
          <MenuRadioGroup
            value={row.permissionMode}
            onValueChange={(value) => void onSetMode(row, value as SessionPermissionMode)}
          >
            {SESSION_PERMISSION_MODES.map((option) => (
              <MenuRadioItem key={option.mode} value={option.mode} closeOnClick>
                {option.label}
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuGroup>
      </MenuPopup>
    </Menu>
  );
}
