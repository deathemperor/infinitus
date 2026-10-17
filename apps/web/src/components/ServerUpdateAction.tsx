import { PRODUCT_NAME } from "@infinitus/shared/productName";
import { useAtomValue } from "@effect/atom-react";
import {
  AuthEnvironmentMaintainScope,
  type AuthSessionState,
  sessionGrantsScope,
} from "@infinitus/contracts";
import type { AsyncResult } from "effect/reactivity";
import { environmentSession } from "~/state/session";
import type {
  EnvironmentId,
  ServerInstallation,
  ServerRunningTurn,
  ServerSelfUpdateCapability,
  ServerUpdateRunningTurnsPolicy,
} from "@infinitus/contracts";
import type { ServerUpdateStage, ServerUpdateState } from "@infinitus/client-runtime/state/server";
import {
  isAtomCommandInterrupted,
  settlePromise,
  squashAtomCommandFailure,
} from "@infinitus/client-runtime/state/runtime";
import { CircleArrowUpIcon } from "lucide-react";
import { type ComponentProps, useRef, useState } from "react";

import { requestConfirmDialog } from "~/confirmDialog";
import { useCopyToClipboard } from "~/hooks/useCopyToClipboard";
import { useEnvironmentSettings } from "~/hooks/useSettings";
import { serverEnvironment, updateOutdatedServer } from "~/state/server";
import { appAtomRegistry } from "~/rpc/atomRegistry";
import { useAtomCommand } from "~/state/use-atom-command";
import { manualServerUpdateCommand } from "~/versionSkew";
import { Button } from "./ui/button";
import { toastManager } from "./ui/toast";
import { Tooltip, TooltipPopup, TooltipTrigger } from "./ui/tooltip";

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
  readonly installation?: ServerInstallation | undefined;
  readonly desktopAppUpdate?: boolean;
  readonly threadContinuation?: boolean;
  readonly targetVersion: string;
  readonly continueThreadsAfterServerUpdate?: boolean;
}

type UpdateButtonProps = Pick<ComponentProps<typeof Button>, "variant" | "size" | "className"> & {
  readonly label?: string;
  readonly appearance?: "button" | "icon";
};

export type ServerUpdateOutcome =
  | { readonly status: "updated" | "skipped" }
  | { readonly status: "failed"; readonly message: string };

/** Toasts its success or failure unless `quiet`; never rejects. */
export function useServerUpdate() {
  const updateServer = useAtomCommand(serverEnvironment.updateServer, { reportFailure: false });
<<<<<<< HEAD
  const update = async (
    target: ServerUpdateTarget,
    failureTitle = "Server update failed",
    runningTurns?: ServerUpdateRunningTurnsPolicy,
  ): Promise<void> => {
=======
  return async (
    target: ServerUpdateTarget,
    { quiet = false }: { readonly quiet?: boolean } = {},
  ): Promise<ServerUpdateOutcome> => {
>>>>>>> upstream-sync-2fbd4318f-upstream-renamed
    const { environmentId, serverLabel, selfUpdate, targetVersion } = target;
    if (
      !canUpdateServer(appAtomRegistry.get(environmentSession.sessionStateAtom(environmentId))) ||
      pendingUpdateEnvironmentIds.has(environmentId)
    )
      return { status: "skipped" };
    pendingUpdateEnvironmentIds.add(environmentId);
<<<<<<< HEAD
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
=======
    const result = await updateServer({
      environmentId,
      input: {
        targetVersion,
        ...(target.threadContinuation && target.continueThreadsAfterServerUpdate
          ? { continueRunningThreads: true }
          : {}),
      },
    });
    pendingUpdateEnvironmentIds.delete(environmentId);
    if (result._tag === "Failure") {
      if (isAtomCommandInterrupted(result)) return { status: "skipped" };
      const message = updateFailureMessage(squashAtomCommandFailure(result));
      if (!quiet) {
        toastManager.add({
          type: "error",
          title: `${serverLabel} update failed`,
          description: message,
        });
>>>>>>> upstream-sync-2fbd4318f-upstream-renamed
      }
      return { status: "failed", message };
    }
    if (!quiet) {
      toastManager.add({
        type: "success",
        title: `${serverLabel} updated`,
        description:
          selfUpdate === "desktop-managed"
            ? `Desktop app relaunched on ${result.value.targetVersion}.`
            : `Reconnected on t3@${result.value.targetVersion}.`,
      });
    }
    return { status: "updated" };
  };
  return update;
}

export function ServerUpdatesAction({
  targets,
  label = "Update all",
  variant = "outline",
  size = "xs",
  className,
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
    await settlePromise(async () => {
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
      await Promise.all(available.map((target) => update(target)));
    });
    pending.current = false;
    setIsPending(false);
  };
  return (
    <Button
      size={size}
      variant={variant}
      className={className}
      disabled={isPending || eligible.length === 0}
      onClick={() => void handleUpdate()}
    >
      {label}
    </Button>
  );
}

export function canUpdateServer(
  result: AsyncResult.AsyncResult<AuthSessionState, unknown>,
): boolean {
  if (result._tag !== "Success" || !result.value.authenticated) return false;
  return sessionGrantsScope(result.value, AuthEnvironmentMaintainScope);
}

<<<<<<< HEAD
/**
 * One-row status for an in-flight server update: "Downloading…" then
 * "Restarting…" (with "Waiting for N running threads…" between them when
 * the server holds the install, #829). The update is a wait, not a warning: a single pulsing dot
 * and label, no step rail, no versions. Failure turns the row red with the
 * rollback reason.
 */
=======
>>>>>>> upstream-sync-2fbd4318f-upstream-renamed
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
          <TooltipPopup side="top">{state.message}</TooltipPopup>
        </Tooltip>
      </div>
    );
  }
  return (
    <div className="mt-1 flex items-center gap-2 text-xs font-medium text-foreground">
<<<<<<< HEAD
      <span
        className="size-1.5 shrink-0 animate-status-pulse rounded-full bg-foreground"
        aria-hidden="true"
      />
      <span>{serverUpdateStageLabel(state.stage, state.runningTurns)}</span>
=======
      <span className="size-1.5 shrink-0 rounded-full bg-foreground" aria-hidden="true" />
      <span>{serverUpdateStageLabel(state.stage)}</span>
>>>>>>> upstream-sync-2fbd4318f-upstream-renamed
    </div>
  );
}

/**
 * Self-updates delegate their full lifecycle to client-runtime so this component can unmount
 * during reconnect without losing operation state.
 */
export function ServerUpdateAction({
  environmentId,
  serverLabel,
  selfUpdate,
  installation,
  desktopAppUpdate = false,
  threadContinuation = false,
  targetVersion,
  label = "Update",
  variant = "outline",
  size = "xs",
  className,
  appearance = "button",
}: Omit<ServerUpdateTarget, "continueThreadsAfterServerUpdate"> & UpdateButtonProps) {
  const isDesktopAppUpdate = selfUpdate === "desktop-managed";
  const sessionStateAtom = environmentSession.sessionStateAtom(environmentId);
  const canUpdate = canUpdateServer(useAtomValue(sessionStateAtom));
  const continueThreadsAfterServerUpdate = useEnvironmentSettings(
    environmentId,
    (settings) => settings.continueThreadsAfterServerUpdate,
  );
  const update = useServerUpdate();
  const { copyToClipboard } = useCopyToClipboard<{ command: string }>({
    target: installation?.kind === "npm-global" ? "update command" : "relaunch command",
    onCopy: ({ command }) => {
      toastManager.add({
        type: "success",
        title:
          installation?.kind === "npm-global" ? "Update command copied" : "Relaunch command copied",
        description:
          installation?.kind === "npm-global"
            ? `Run \`${command}\` on ${serverLabel}, then restart t3 with your usual options.`
            : `Stop t3 on ${serverLabel}, then relaunch with \`${command}\` using the same subcommand and options. This does not update an installed t3 command.`,
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
    if (
      !canUpdateServer(appAtomRegistry.get(sessionStateAtom)) ||
      pendingUpdateEnvironmentIds.has(environmentId)
    ) {
      return;
    }
    if (isDesktopAppUpdate) {
      const confirmed =
        (await requestConfirmDialog(
          `Update the ${PRODUCT_NAME} desktop app that runs the ${serverLabel}? It will close and relaunch on that machine.`,
        )) ?? true;
      if (!confirmed) {
        return;
      }
    }
    if (!canUpdateServer(appAtomRegistry.get(sessionStateAtom))) return;
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

  const manualCommand =
    selfUpdate === null ? manualServerUpdateCommand(targetVersion, installation) : null;
  const actionLabel =
    manualCommand !== null
      ? installation?.kind === "npm-global"
        ? "Copy update command"
        : "Copy relaunch command"
      : label;
  const onClick =
    manualCommand !== null
      ? () => copyToClipboard(manualCommand, { command: manualCommand })
      : () => void handleUpdate();

  if (appearance === "icon") {
    return (
      <Tooltip>
        <TooltipTrigger
          render={
            <Button
              size="icon-xs"
              variant="ghost-muted"
              className={className}
              aria-label={`${actionLabel} for ${serverLabel}`}
              disabled={manualCommand === null && !canUpdate}
              onClick={onClick}
            />
          }
        >
          <CircleArrowUpIcon className="size-3.5" />
        </TooltipTrigger>
        <TooltipPopup side="top">{actionLabel}</TooltipPopup>
      </Tooltip>
    );
  }

  return (
    <Button
      size={size}
      variant={variant}
      className={className}
      disabled={manualCommand === null && !canUpdate}
      onClick={onClick}
    >
      {actionLabel}
    </Button>
  );
}

/**
 * Its version comes from the host descriptor because the host never delivers a server config.
 */
export function OutdatedServerUpdateAction({
  environmentId,
  serverLabel,
  fromVersion,
  targetVersion,
  label = "Update",
}: {
  readonly environmentId: EnvironmentId;
  readonly serverLabel: string;
  readonly fromVersion: string | undefined;
  readonly targetVersion: string;
  readonly label?: string;
}) {
  const update = useAtomCommand(updateOutdatedServer, { reportFailure: false });
  const handleUpdate = async () => {
    if (pendingUpdateEnvironmentIds.has(environmentId)) return;
    pendingUpdateEnvironmentIds.add(environmentId);
    const result = await update({
      environmentId,
      input: { targetVersion },
      ...(fromVersion === undefined ? {} : { fromVersion }),
    });
    pendingUpdateEnvironmentIds.delete(environmentId);
    if (result._tag === "Failure") {
      if (isAtomCommandInterrupted(result)) return;
      toastManager.add({
        type: "error",
        title: `${serverLabel} update failed`,
        description: updateFailureMessage(squashAtomCommandFailure(result)),
      });
      return;
    }
    toastManager.add({
      type: "success",
      title: `${serverLabel} updated`,
      description: `Reconnected on t3@${result.value.targetVersion}.`,
    });
  };
  return (
    <Button size="xs" variant="outline" onClick={() => void handleUpdate()}>
      {label}
    </Button>
  );
}
