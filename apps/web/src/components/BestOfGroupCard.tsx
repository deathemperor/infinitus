import { scopeProjectRef, scopeThreadRef } from "@t3tools/client-runtime/environment";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import type { EnvironmentId, ProjectId, ThreadId } from "@t3tools/contracts";
import { useNavigate } from "@tanstack/react-router";
import { CheckIcon, FlaskConicalIcon } from "lucide-react";
import { useCallback, useMemo, useState } from "react";

import { useThreadActions } from "../hooks/useThreadActions";
import { cn } from "../lib/utils";
import { readThreadShell, useProject, useThreadShells } from "../state/entities";
import { threadEnvironment } from "../state/threads";
import { useAtomCommand } from "../state/use-atom-command";
import { vcsEnvironment } from "../state/vcs";
import { buildThreadRouteParams } from "../threadRoutes";
import { BEST_OF_STATUS_LABEL, bestOfMemberStatus, bestOfSiblings } from "./chat/bestOf.logic";
import { Button } from "./ui/button";
import { Spinner } from "./ui/spinner";

/** How long "Keep this one" waits for an interrupted sibling to go idle. */
const KEEP_IDLE_WAIT_MS = 8_000;

function waitForIdle(
  environmentId: EnvironmentId,
  threadId: ThreadId,
  signal: { readonly until: number },
): Promise<void> {
  return new Promise((resolve) => {
    const tick = () => {
      const shell = readThreadShell(scopeThreadRef(environmentId, threadId));
      const busy = shell?.session?.status === "running" && shell.session.activeTurnId !== null;
      if (!busy || Date.now() >= signal.until) {
        resolve();
        return;
      }
      setTimeout(tick, 250);
    };
    tick();
  });
}

/**
 * Best of N (#269 B): the card at the top of every member thread. It lists
 * the group's live siblings with one word of status each, links to them,
 * and "Keep this one" archives the others: a running sibling is interrupted
 * first, and its worktree is removed with its work kept on the branch, so
 * nothing a losing run wrote is lost. The card goes away once this thread
 * is the only live member.
 */
export function BestOfGroupCard({
  environmentId,
  projectId,
  threadId,
  groupId,
}: {
  environmentId: EnvironmentId;
  projectId: ProjectId;
  threadId: ThreadId;
  groupId: string;
}) {
  const shells = useThreadShells();
  const project = useProject(
    useMemo(() => scopeProjectRef(environmentId, projectId), [environmentId, projectId]),
  );
  const siblings = useMemo(
    () =>
      bestOfSiblings(
        shells.filter((shell) => shell.environmentId === environmentId),
        groupId,
      ),
    [environmentId, groupId, shells],
  );
  const navigate = useNavigate();
  const { archiveThread } = useThreadActions();
  const interruptTurn = useAtomCommand(threadEnvironment.interruptTurn, { reportFailure: false });
  const removeWorktree = useAtomCommand(vcsEnvironment.removeWorktree, { reportFailure: false });
  const updateThreadMetadata = useAtomCommand(threadEnvironment.updateMetadata, {
    reportFailure: false,
  });
  const [keeping, setKeeping] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const keepThisOne = useCallback(async () => {
    setKeeping(true);
    setError(null);
    const failures: string[] = [];
    for (const sibling of siblings) {
      if (sibling.id === threadId) continue;
      const ref = scopeThreadRef(environmentId, sibling.id);
      if (sibling.session?.activeTurnId) {
        await interruptTurn({ environmentId, input: { threadId: sibling.id } });
        await waitForIdle(environmentId, sibling.id, { until: Date.now() + KEEP_IDLE_WAIT_MS });
      }
      const archived = await archiveThread(ref);
      if (archived._tag === "Failure") {
        if (isAtomCommandInterrupted(archived)) continue;
        const cause = squashAtomCommandFailure(archived);
        failures.push(
          cause instanceof Error ? cause.message : `Could not archive ${sibling.title}.`,
        );
        continue;
      }
      if (sibling.worktreePath && project) {
        const removed = await removeWorktree({
          environmentId,
          input: {
            cwd: project.workspaceRoot,
            path: sibling.worktreePath,
            force: true,
            keepWork: true,
            deleteBranch: false,
          },
        });
        if (removed._tag === "Failure") {
          if (isAtomCommandInterrupted(removed)) continue;
          const cause = squashAtomCommandFailure(removed);
          failures.push(
            cause instanceof Error
              ? cause.message
              : `Could not remove ${sibling.title}'s worktree.`,
          );
          continue;
        }
        // The path is gone; the archived thread stops counting as a worktree holder.
        await updateThreadMetadata({
          environmentId,
          input: { threadId: sibling.id, worktreePath: null },
        });
      }
    }
    setKeeping(false);
    if (failures.length > 0) setError(failures.join(" "));
  }, [
    archiveThread,
    environmentId,
    interruptTurn,
    project,
    removeWorktree,
    siblings,
    threadId,
    updateThreadMetadata,
  ]);

  if (siblings.length < 2) return null;

  return (
    <div
      className="border-border/60 bg-muted/30 mx-3 mt-2 rounded-lg border px-3 py-2 text-sm"
      data-testid="best-of-group-card"
    >
      <div className="flex items-center gap-2">
        <FlaskConicalIcon aria-hidden className="text-muted-foreground size-4" />
        <span className="font-medium">Best of {siblings.length}</span>
        <span className="text-muted-foreground text-xs">same prompt, one worktree each</span>
        <div className="ml-auto flex items-center gap-2">
          {keeping ? <Spinner className="size-3.5" /> : null}
          <Button
            size="xs"
            variant="outline"
            type="button"
            disabled={keeping}
            data-testid="best-of-keep"
            onClick={() => void keepThisOne()}
          >
            <CheckIcon aria-hidden className="size-3.5" />
            Keep this one
          </Button>
        </div>
      </div>
      <ul className="mt-1.5 flex flex-col gap-0.5">
        {siblings.map((sibling) => {
          const status = bestOfMemberStatus(sibling);
          const current = sibling.id === threadId;
          return (
            <li key={sibling.id} className="flex items-center gap-2 text-xs">
              <button
                type="button"
                className={cn(
                  "min-w-0 flex-1 truncate text-left hover:underline",
                  current && "font-medium",
                )}
                aria-current={current ? "page" : undefined}
                onClick={() => {
                  if (current) return;
                  void navigate({
                    to: "/$environmentId/$threadId",
                    params: buildThreadRouteParams(scopeThreadRef(environmentId, sibling.id)),
                  });
                }}
              >
                {sibling.modelSelection.model}
                {current ? " (this thread)" : ""}
              </button>
              <span
                className={cn(
                  "text-muted-foreground shrink-0",
                  (status === "waiting-approval" || status === "waiting-input") && "text-warning",
                  status === "failed" && "text-destructive",
                )}
              >
                {BEST_OF_STATUS_LABEL[status]}
              </span>
            </li>
          );
        })}
      </ul>
      {error ? <p className="text-destructive mt-1 text-xs">{error}</p> : null}
    </div>
  );
}
