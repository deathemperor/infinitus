import { useAtomValue } from "@effect/atom-react";
import { scopeProjectRef } from "@t3tools/client-runtime/environment";
import {
  canMoveSession,
  idleMoveableRows,
  movedThreadId,
  nudgeCommandArgs,
  nudgeOutcome,
  SESSION_PERMISSION_MODES,
  type SessionActions,
  type SessionCommandArgs,
  sessionModeCommandArgs,
  type SessionMoveBatch,
  sessionMoveBatches,
  type SessionPermissionMode,
  type SessionRowModel,
  showSessionCommandArgs,
} from "@t3tools/client-runtime/state/infinitusSessions";
import { squashAtomCommandFailure } from "@t3tools/client-runtime/state/runtime";
import { CommandId, type ProjectId, type ThreadId } from "@t3tools/contracts";
import { Link, useNavigate } from "@tanstack/react-router";
import * as Cause from "effect/Cause";
import * as Schema from "effect/Schema";
import { ArrowRightIcon, ChevronRightIcon, PlayIcon } from "lucide-react";
import { memo, useMemo, useState } from "react";

import { useLocalStorage } from "../../hooks/useLocalStorage";
import { useNowMinute } from "../../hooks/useNowMinute";
import { findProjectByPath, inferProjectTitleFromPath } from "../../lib/projectPaths";
import { cn, newProjectId } from "../../lib/utils";
import { agentSessionImport } from "../../state/agentSessions";
import { readProjects, waitForProject } from "../../state/entities";
import { usePrimaryEnvironmentId } from "../../state/environments";
import { infinitusEnvironment } from "../../state/infinitus";
import { projectEnvironment } from "../../state/projects";
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

const MOVED_COPY = "Close the terminal session; the thread carries on here.";

/**
 * The footer's Sessions group: the Claude Code sessions the Mac tracks, the
 * ones needing a person first. A row click opens the session's chat window on
 * the Mac (`show session <pid>`, #612) when the build has it; the row's menu
 * carries "Nudge" (`nudge <pid>`), the permission-mode radio (`session-mode`),
 * each only when the manifest lists the verb, and "Move to a thread" (#648)
 * when the row has a session id: the cwd becomes a project if it is not one,
 * the transcript is imported as a thread and the thread opens. "Move idle" in
 * the header does that for every idle row. The terminal session is never
 * killed or typed into — the moved row asks the person to close it.
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
  const createProject = useAtomCommand(projectEnvironment.create, { reportFailure: false });
  const importThreads = useAtomCommand(agentSessionImport, { reportFailure: false });
  const navigate = useNavigate();
  const [note, setNote] = useState<RowNote | null>(null);
  /** sessionId → thread, for the rows moved in this page's lifetime. A reload
      forgets it; moving again is safe (the import finds the thread it made). */
  const [moved, setMoved] = useState<ReadonlyMap<string, ThreadId>>(() => new Map());
  const [moving, setMoving] = useState(false);

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

  /** The project rooted at `cwd` on this environment, created when missing
      and awaited in the client store so the import that follows can find it. */
  const ensureProject = async (cwd: string): Promise<ProjectId> => {
    const existing = findProjectByPath(
      readProjects().filter((project) => project.environmentId === environmentId),
      cwd,
    );
    if (existing !== undefined) return existing.id;
    const projectId = newProjectId();
    const result = await createProject({
      environmentId,
      input: {
        projectId,
        commandId: CommandId.make(`infinitus:sessions:move:${projectId}`),
        title: inferProjectTitleFromPath(cwd),
        workspaceRoot: cwd,
        createWorkspaceRootIfMissing: false,
        defaultModelSelection: null,
      },
    });
    if (result._tag !== "Success") throw squashAtomCommandFailure(result);
    await waitForProject(scopeProjectRef(environmentId, projectId));
    return projectId;
  };

  /** One batch: the folder is a project (found, else created and awaited),
      then its sessions are imported; returns where each one landed, and how
      many requested transcripts were found but could not be imported. */
  const moveBatch = async (
    batch: SessionMoveBatch,
  ): Promise<{ threads: ReadonlyMap<string, ThreadId>; skippedCount: number }> => {
    const projectId = await ensureProject(batch.cwd);
    const result = await importThreads({
      environmentId,
      input: {
        projectId,
        expectedWorkspaceRoot: batch.cwd,
        providerSessionIds: [...batch.sessionIds],
      },
    });
    if (result._tag !== "Success") throw squashAtomCommandFailure(result);
    const threads = new Map<string, ThreadId>();
    for (const sessionId of batch.sessionIds) {
      const threadId = movedThreadId(result.value, sessionId);
      if (threadId !== null) threads.set(sessionId, threadId);
    }
    setMoved((previous) => new Map([...previous, ...threads]));
    return { threads, skippedCount: result.value.skippedCount };
  };

  const move = async (row: SessionRowModel) => {
    if (row.sessionId === null || moving) return;
    setMoving(true);
    try {
      const { threads, skippedCount } = await moveBatch({
        cwd: row.cwd,
        sessionIds: [row.sessionId],
      });
      const threadId = threads.get(row.sessionId);
      if (threadId === undefined) {
        // With a filter, skipped counts only the requested transcripts: found
        // but not importable (the server log says why), else not found at all.
        setNote({
          pid: row.pid,
          message:
            skippedCount > 0
              ? "The session's transcript could not be imported; the server log has the reason."
              : "No transcript of this session was found in its folder.",
        });
        return;
      }
      setNote(null);
      void navigate({ to: "/$environmentId/$threadId", params: { environmentId, threadId } });
    } catch (error) {
      setNote({ pid: row.pid, message: sessionCommandErrorMessage(error) });
    } finally {
      setMoving(false);
    }
  };

  const idleRows = idleMoveableRows(view.rows).filter(
    (row) => row.sessionId !== null && !moved.has(row.sessionId),
  );
  const moveAllIdle = async () => {
    if (moving) return;
    setMoving(true);
    try {
      for (const batch of sessionMoveBatches(idleRows)) {
        try {
          await moveBatch(batch);
        } catch (error) {
          const first = idleRows.find((row) => row.cwd === batch.cwd);
          if (first !== undefined) {
            setNote({ pid: first.pid, message: sessionCommandErrorMessage(error) });
          }
        }
      }
    } finally {
      setMoving(false);
    }
  };

  return (
    <Collapsible open={open} onOpenChange={setOpen} className="flex flex-col">
      {/* The trigger is a button, so the header action sits beside it, not inside. */}
      <div className="flex items-center">
        <CollapsibleTrigger className="flex h-7 min-w-0 flex-1 items-center gap-1.5 rounded-lg px-2 text-left text-muted-foreground text-xs font-medium hover:bg-sidebar-row-hover">
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
        {idleRows.length > 0 ? (
          <Tooltip>
            <TooltipTrigger
              render={
                <button
                  type="button"
                  disabled={moving}
                  onClick={() => void moveAllIdle()}
                  className="h-7 shrink-0 rounded-lg px-2 text-[11px] text-muted-foreground hover:bg-sidebar-row-hover disabled:opacity-50"
                >
                  Move idle
                </button>
              }
            />
            <TooltipPopup side="top">
              Move every idle session into a thread; busy and waiting ones stay.
            </TooltipPopup>
          </Tooltip>
        ) : null}
      </div>
      <CollapsiblePanel>
        <ul className="flex max-h-48 flex-col gap-0.5 overflow-y-auto py-0.5">
          {view.rows.map((row) => {
            const movedTo = row.sessionId === null ? undefined : moved.get(row.sessionId);
            return (
              <li key={row.pid} className="flex flex-col">
                <SessionRow
                  row={row}
                  actions={view.actions}
                  moving={moving}
                  onShow={show}
                  onNudge={nudge}
                  onSetMode={setMode}
                  onMove={move}
                />
                {row.needs.map((need) => (
                  <span key={need} className="px-2 pb-0.5 text-[11px] text-warning-foreground">
                    {need}
                  </span>
                ))}
                {movedTo !== undefined ? (
                  <span className="px-2 pb-1 text-[11px] text-muted-foreground">
                    Moved to{" "}
                    <Link
                      to="/$environmentId/$threadId"
                      params={{ environmentId, threadId: movedTo }}
                      className="underline underline-offset-2"
                    >
                      a thread
                    </Link>
                    . {MOVED_COPY}
                  </span>
                ) : null}
                {note?.pid === row.pid ? (
                  <span className="px-2 pb-1 text-[11px] text-destructive">{note.message}</span>
                ) : null}
              </li>
            );
          })}
        </ul>
      </CollapsiblePanel>
    </Collapsible>
  );
});

function SessionRow({
  row,
  actions,
  moving,
  onShow,
  onNudge,
  onSetMode,
  onMove,
}: {
  row: SessionRowModel;
  actions: SessionActions;
  moving: boolean;
  onShow: (row: SessionRowModel) => void;
  onNudge: (row: SessionRowModel) => Promise<void>;
  onSetMode: (row: SessionRowModel, mode: SessionPermissionMode) => void;
  onMove: (row: SessionRowModel) => Promise<void>;
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
  const canMove = canMoveSession(row);
  const hasMenu = actions.nudge || actions.setMode || canMove;

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
      {canMove ? (
        <MenuItem disabled={moving} onClick={() => void onMove(row)}>
          <ArrowRightIcon aria-hidden />
          Move to a thread
        </MenuItem>
      ) : null}
      {(actions.nudge || canMove) && actions.setMode ? <MenuSeparator /> : null}
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
