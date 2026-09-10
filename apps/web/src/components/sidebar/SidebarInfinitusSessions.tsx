import { useAtomValue } from "@effect/atom-react";
import {
  nudgeCommandArgs,
  nudgeOutcome,
  SESSION_PERMISSION_MODES,
  type SessionActions,
  type SessionCommandArgs,
  sessionModeCommandArgs,
  type SessionPermissionMode,
  type SessionRowModel,
  showSessionCommandArgs,
} from "@t3tools/client-runtime/state/infinitusSessions";
import * as Cause from "effect/Cause";
import * as Schema from "effect/Schema";
import { ChevronRightIcon, PlayIcon } from "lucide-react";
import { memo, useMemo, useState } from "react";

import { useLocalStorage } from "../../hooks/useLocalStorage";
import { useNowMinute } from "../../hooks/useNowMinute";
import { cn } from "../../lib/utils";
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
  MenuItem,
  MenuPopup,
  MenuRadioGroup,
  MenuRadioItem,
  MenuSeparator,
  MenuTrigger,
} from "../ui/menu";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";
import {
  sessionCommandErrorMessage,
  sessionRowDetail,
  sidebarSessionsView,
} from "./sidebarInfinitusSessions.logic";

const OPEN_KEY = "infinitus.sidebarSessionsOpen";

const STATE_DOT: Record<SessionRowModel["state"], string> = {
  waiting: "bg-warning",
  working: "bg-primary",
  idle: "bg-muted-foreground/50",
  shell: "bg-muted-foreground/50",
  unknown: "bg-muted-foreground/30",
};

/** A line shown under a row after a command: the socket's error, or the
    nudge reply's reason when the nudge did not land. */
interface RowNote {
  readonly pid: number;
  readonly message: string;
}

/**
 * The footer's Sessions group: the Claude Code sessions the Mac tracks, the
 * ones needing a person first. A row click opens the session's chat window on
 * the Mac (`show session <pid>`, #612) when the build has it; the row's menu
 * carries "Nudge" (`nudge <pid>`) and the permission-mode radio
 * (`session-mode`), each only when the manifest lists the verb.
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
  // Ages tick with the shared minute clock, so every row re-reads at once.
  const minute = useNowMinute();
  const view = useMemo(
    () => sidebarSessionsView({ capability, snapshot, now: Date.parse(minute) }),
    [capability, snapshot, minute],
  );
  const [open, setOpen] = useLocalStorage(OPEN_KEY, true, Schema.Boolean);
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [note, setNote] = useState<RowNote | null>(null);

  if (view === null || environmentId === null) return null;

  const run = async (row: SessionRowModel, { command, args }: SessionCommandArgs) => {
    const result = await runCommand({
      environmentId,
      input: { command, args: [...args], options: {} },
    });
    if (result._tag !== "Success") {
      setNote({ pid: row.pid, message: sessionCommandErrorMessage(Cause.squash(result.cause)) });
      return null;
    }
    setNote(null);
    return result.value.result;
  };

  const setMode = (row: SessionRowModel, mode: SessionPermissionMode) => {
    if (mode !== row.permissionMode) void run(row, sessionModeCommandArgs(row, mode));
  };
  const show = (row: SessionRowModel) => void run(row, showSessionCommandArgs(row));
  const nudge = async (row: SessionRowModel) => {
    const reply = await run(row, nudgeCommandArgs(row));
    if (reply === null) return;
    const outcome = nudgeOutcome(reply);
    if (!outcome.nudged) {
      setNote({ pid: row.pid, message: outcome.reason ?? "The session was not nudged." });
    }
  };

  return (
    <Collapsible open={open} onOpenChange={setOpen} className="flex flex-col">
      <CollapsibleTrigger className="flex h-7 w-full items-center gap-1.5 rounded-lg px-2 text-left text-muted-foreground text-xs font-medium hover:bg-sidebar-row-hover">
        <ChevronRightIcon
          className={cn("size-3.5 shrink-0 transition-transform", open && "rotate-90")}
          aria-hidden
        />
        <span className="min-w-0 flex-1 truncate">Sessions</span>
        {view.attentionCount > 0 ? (
          <span className="rounded-full bg-warning/16 px-1.5 text-[10px] font-semibold text-warning-foreground tabular-nums">
            {view.attentionCount}
          </span>
        ) : null}
        <span className="text-[10px] tabular-nums">{view.rows.length}</span>
      </CollapsibleTrigger>
      <CollapsiblePanel>
        <ul className="flex max-h-48 flex-col gap-0.5 overflow-y-auto py-0.5">
          {view.rows.map((row) => (
            <li key={row.pid} className="flex flex-col">
              <SessionRow
                row={row}
                actions={view.actions}
                onShow={show}
                onNudge={nudge}
                onSetMode={setMode}
              />
              {row.needs.map((need) => (
                <span key={need} className="px-2 pb-0.5 text-[11px] text-warning-foreground">
                  {need}
                </span>
              ))}
              {note?.pid === row.pid ? (
                <span className="px-2 pb-1 text-[11px] text-destructive">{note.message}</span>
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
  actions,
  onShow,
  onNudge,
  onSetMode,
}: {
  row: SessionRowModel;
  actions: SessionActions;
  onShow: (row: SessionRowModel) => void;
  onNudge: (row: SessionRowModel) => Promise<void>;
  onSetMode: (row: SessionRowModel, mode: SessionPermissionMode) => void;
}) {
  const detail = [row.title, row.stateLabel, row.account, row.age, row.cwd]
    .filter((part) => part !== null)
    .join(" · ");
  const body = (
    <>
      <span className={cn("size-2 shrink-0 rounded-full", STATE_DOT[row.state])} aria-hidden />
      <span className="min-w-0 flex-1 truncate text-sidebar-foreground">{row.title}</span>
      <Tooltip>
        <TooltipTrigger
          render={
            <span className="max-w-[50%] shrink-0 truncate text-muted-foreground">
              {sessionRowDetail(row)}
            </span>
          }
        />
        <TooltipPopup side="top">{detail}</TooltipPopup>
      </Tooltip>
      {row.age !== null ? (
        <span className="shrink-0 text-[10px] text-muted-foreground tabular-nums">{row.age}</span>
      ) : null}
    </>
  );
  const className =
    "flex h-6 w-full min-w-0 flex-1 items-center gap-2 rounded-md px-2 text-left text-xs hover:bg-sidebar-row-hover";
  const hasMenu = actions.nudge || actions.setMode;

  const main = actions.show ? (
    <button
      type="button"
      aria-label={`Open ${row.title}`}
      className={className}
      onClick={() => onShow(row)}
    >
      {body}
    </button>
  ) : hasMenu ? null : (
    <div className={className}>{body}</div>
  );

  if (!hasMenu) return main;

  const menu = (
    <MenuPopup align="start" side="top" className="w-56">
      {actions.nudge ? (
        <MenuItem onClick={() => void onNudge(row)}>
          <PlayIcon aria-hidden />
          Nudge
        </MenuItem>
      ) : null}
      {actions.nudge && actions.setMode ? <MenuSeparator /> : null}
      {actions.setMode ? (
        <MenuGroup>
          <MenuGroupLabel>Permission mode</MenuGroupLabel>
          <MenuRadioGroup
            value={row.permissionMode}
            onValueChange={(value) => onSetMode(row, value as SessionPermissionMode)}
          >
            {SESSION_PERMISSION_MODES.map((option) => (
              <MenuRadioItem key={option.mode} value={option.mode} closeOnClick>
                {option.label}
              </MenuRadioItem>
            ))}
          </MenuRadioGroup>
        </MenuGroup>
      ) : null}
    </MenuPopup>
  );

  // With a show verb the click opens the session and the menu sits behind a
  // small trigger; without one the whole row is the menu trigger, as before.
  if (main === null) {
    return (
      <Menu>
        <MenuTrigger
          render={
            <button type="button" aria-label={`${row.title} actions`} className={className}>
              {body}
            </button>
          }
        />
        {menu}
      </Menu>
    );
  }
  return (
    <div className="flex items-center">
      {main}
      <Menu>
        <MenuTrigger
          render={
            <button
              type="button"
              aria-label={`${row.title} actions`}
              className="flex size-6 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-sidebar-row-hover"
            >
              <span aria-hidden>⋯</span>
            </button>
          }
        />
        {menu}
      </Menu>
    </div>
  );
}
