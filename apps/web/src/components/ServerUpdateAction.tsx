import type {
  EnvironmentId,
  ServerRunningTurn,
  ServerSelfUpdateCapability,
  ServerUpdateRunningTurnsPolicy,
} from "@t3tools/contracts";
import type { ServerUpdateStage, ServerUpdateState } from "@t3tools/client-runtime/state/server";
import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import { type ComponentProps, useRef, useState } from "react";

import { requestConfirmDialog } from "~/confirmDialog";
import { useCopyToClipboard } from "~/hooks/useCopyToClipboard";
import { useEnvironmentSettings } from "~/hooks/useSettings";
import { serverEnvironment } from "~/state/server";
import { useAtomCommand } from "~/state/use-atom-command";
import { manualServerUpdateCommand } from "~/versionSkew";
import { Button } from "./ui/button";
import { toastManager } from "./ui/toast";
import { Tooltip, TooltipPopup, TooltipTrigger } from "./ui/tooltip";
import { PRODUCT_NAME } from "@t3tools/shared/productName";

// The wire "installing" stage is a sub-second launcher handoff, so the UI
// folds it into the download phase; everything after the handoff is the
// restart the user is actually waiting through.
const UPDATE_STAGE_LABELS: Record<ServerUpdateStage, string> = {
  waiting: "Waiting for running threads…",
  downloading: "Downloading…",
  installing: "Downloading…",
  resuming: "Restarting…",
};
const pendingUpdateEnvironmentIds = new Set<EnvironmentId>();

export function serverUpdateStageLabel(stage: ServerUpdateStage, runningTurns?: number): string {
  if (stage === "waiting" && runningTurns !== undefined) {
    return `Waiting for ${runningThreadsPhrase(runningTurns)} to finish…`;
  }
  return UPDATE_STAGE_LABELS[stage];
}

function updateFailureMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Server update failed.";
}

function runningThreadsPhrase(count: number): string {
  return count === 1 ? "1 running thread" : `${count} running threads`;
}

/**
 * The turns an update was refused over (#829): the server names them when
 * the request carried no policy for running turns. Anything else is an
 * ordinary failure.
 */
function refusedRunningTurns(error: unknown): ReadonlyArray<ServerRunningTurn> | null {
  if (typeof error !== "object" || error === null) return null;
  const candidate = error as { readonly _tag?: unknown; readonly runningTurns?: unknown };
  if (candidate._tag !== "ServerSelfUpdateError" || !Array.isArray(candidate.runningTurns)) {
    return null;
  }
  return candidate.runningTurns.length > 0 ? candidate.runningTurns : null;
}

export interface ServerUpdateTarget {
  readonly environmentId: EnvironmentId;
  readonly serverLabel: string;
  readonly selfUpdate: ServerSelfUpdateCapability | null;
  readonly desktopAppUpdate?: boolean;
  readonly threadContinuation?: boolean;
  readonly targetVersion: string;
  readonly continueThreadsAfterServerUpdate?: boolean;
}

type UpdateButtonProps = Pick<ComponentProps<typeof Button>, "variant" | "size"> & {
  readonly label?: string;
};

function useServerUpdate() {
  const updateServer = useAtomCommand(serverEnvironment.updateServer, { reportFailure: false });
  const update = async (
    target: ServerUpdateTarget,
    failureTitle = "Server update failed",
    runningTurns?: ServerUpdateRunningTurnsPolicy,
  ): Promise<void> => {
    const { environmentId, serverLabel, selfUpdate, targetVersion } = target;
    if (pendingUpdateEnvironmentIds.has(environmentId)) return;
    pendingUpdateEnvironmentIds.add(environmentId);
    try {
      const result = await updateServer({
        environmentId,
        input: {
          targetVersion,
          ...(target.threadContinuation && target.continueThreadsAfterServerUpdate
            ? { continueRunningThreads: true }
            : {}),
          ...(runningTurns !== undefined ? { runningTurns } : {}),
        },
      });
      if (result._tag === "Failure") {
        if (isAtomCommandInterrupted(result)) return;
        const error = squashAtomCommandFailure(result);
        const refused = runningTurns === undefined ? refusedRunningTurns(error) : null;
        if (refused === null) throw error;
        // #829: the server refused rather than cut the turns off. Offer the
        // two policies; dismissing the toast leaves the update for later.
        const toastId = toastManager.add({
          type: "warning",
          title: `${runningThreadsPhrase(refused.length)} on ${serverLabel}`,
          description: "Updating now would interrupt them.",
          timeout: 0,
          actionProps: {
            children: "Update when they finish",
            onClick: () => void update(target, failureTitle, "wait"),
          },
          data: {
            actionVariant: "outline",
            hideCopyButton: true,
            secondaryActionProps: {
              children: "Update now",
              onClick: () => {
                toastManager.close(toastId);
                void update(target, failureTitle, "interrupt");
              },
            },
            secondaryActionVariant: "outline",
          },
        });
        return;
      }
      toastManager.add({
        type: "success",
        title: `${serverLabel} updated`,
        description:
          selfUpdate === "desktop-managed"
            ? `Desktop app relaunched on ${result.value.targetVersion}.`
            : `Reconnected on t3@${result.value.targetVersion}.`,
      });
    } catch (error) {
      toastManager.add({
        type: "error",
        title: failureTitle,
        description: updateFailureMessage(error),
      });
    } finally {
      pendingUpdateEnvironmentIds.delete(environmentId);
    }
  };
  return update;
}

/** Updates eligible machines independently; manual paths remain in the machine list. */
export function ServerUpdatesAction({
  targets,
  label = "Update all",
  variant = "outline",
  size = "xs",
}: UpdateButtonProps & {
  readonly targets: ReadonlyArray<ServerUpdateTarget>;
}) {
  const update = useServerUpdate();
  const pending = useRef(false);
  const [isPending, setIsPending] = useState(false);
  const eligible = targets.filter(
    (target) =>
      target.selfUpdate !== null &&
      (target.selfUpdate !== "desktop-managed" || target.desktopAppUpdate),
  );
  const handleUpdate = async () => {
    if (pending.current) return;
    pending.current = true;
    setIsPending(true);
    try {
      const available = eligible.filter(
        (target) => !pendingUpdateEnvironmentIds.has(target.environmentId),
      );
      const desktopTargets = available.filter((target) => target.selfUpdate === "desktop-managed");
      if (desktopTargets.length > 0) {
        const confirmed =
          (await requestConfirmDialog(
            `Update the ${PRODUCT_NAME} desktop apps on ${desktopTargets.map((target) => target.serverLabel).join(", ")}? They will close and relaunch on those machines.`,
          )) ?? true;
        if (!confirmed) return;
      }
      await Promise.all(
        available.map((target) => update(target, `${target.serverLabel} update failed`)),
      );
    } finally {
      pending.current = false;
      setIsPending(false);
    }
  };
  return (
    <Button
      size={size}
      variant={variant}
      disabled={isPending || eligible.length === 0}
      onClick={() => void handleUpdate()}
    >
      {label}
    </Button>
  );
}

/**
 * One-row status for an in-flight server update: "Downloading…" then
 * "Restarting…" (with "Waiting for N running threads…" between them when
 * the server holds the install, #829). The update is a wait, not a warning: a single pulsing dot
 * and label, no step rail, no versions. Failure turns the row red with the
 * rollback reason.
 */
export function ServerUpdateProgress({
  state,
}: {
  readonly state: Exclude<ServerUpdateState, { status: "idle" }>;
}) {
  if (state.status === "failed") {
    return (
      <div className="mt-1 flex min-w-0 items-center gap-2 text-xs text-destructive" role="alert">
        <span className="size-1.5 shrink-0 rounded-full bg-destructive" aria-hidden="true" />
        <Tooltip>
          <TooltipTrigger render={<span className="min-w-0 truncate">{state.message}</span>} />
          <TooltipPopup side="top" className="max-w-80">
            {state.message}
          </TooltipPopup>
        </Tooltip>
      </div>
    );
  }
  return (
    <div className="mt-1 flex items-center gap-2 text-xs font-medium text-foreground">
      <span
        className="size-1.5 shrink-0 animate-status-pulse rounded-full bg-foreground"
        aria-hidden="true"
      />
      <span>{serverUpdateStageLabel(state.stage, state.runningTurns)}</span>
    </div>
  );
}

/**
 * Offers the update path advertised by a version-skewed server. Self-updates
 * delegate their full lifecycle to client-runtime so this component can
 * unmount during reconnect without losing operation state.
 */
export function ServerUpdateAction({
  environmentId,
  serverLabel,
  selfUpdate,
  desktopAppUpdate = false,
  threadContinuation = false,
  targetVersion,
  label = "Update",
  variant = "outline",
  size = "xs",
}: Omit<ServerUpdateTarget, "continueThreadsAfterServerUpdate"> & UpdateButtonProps) {
  const isDesktopAppUpdate = selfUpdate === "desktop-managed";
  const continueThreadsAfterServerUpdate = useEnvironmentSettings(
    environmentId,
    (settings) => settings.continueThreadsAfterServerUpdate,
  );
  const update = useServerUpdate();
  const { copyToClipboard } = useCopyToClipboard<{ command: string }>({
    target: "update command",
    onCopy: ({ command }) => {
      toastManager.add({
        type: "success",
        title: "Update command copied",
        description: `Run \`${command}\` on ${serverLabel} to update it.`,
      });
    },
    onError: (error) => {
      toastManager.add({
        type: "error",
        title: "Could not copy update command",
        description: error.message,
      });
    },
  });

  const handleUpdate = async () => {
    if (pendingUpdateEnvironmentIds.has(environmentId)) {
      return;
    }
    if (isDesktopAppUpdate) {
      // No themed host mounted (undefined) means proceed: the click itself
      // was the request. This is the only confirmation in the flow; the
      // remote machine installs without asking anyone there.
      const confirmed =
        (await requestConfirmDialog(
          `Update the ${PRODUCT_NAME} desktop app that runs the ${serverLabel}? It will close and relaunch on that machine.`,
        )) ?? true;
      if (!confirmed) {
        return;
      }
    }
    await update({
      environmentId,
      serverLabel,
      selfUpdate,
      desktopAppUpdate,
      threadContinuation,
      targetVersion,
      continueThreadsAfterServerUpdate,
    });
  };

  if (selfUpdate === "desktop-managed" && !desktopAppUpdate) {
    return (
      <span className="text-muted-foreground text-xs">
        Update the desktop app on that machine to update this server.
      </span>
    );
  }

  if (selfUpdate === null) {
    const command = manualServerUpdateCommand(targetVersion);
    return (
      <Button size={size} variant={variant} onClick={() => copyToClipboard(command, { command })}>
        Copy update command
      </Button>
    );
  }

  return (
    <Button size={size} variant={variant} onClick={() => void handleUpdate()}>
      {label}
    </Button>
  );
}
