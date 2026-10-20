import type {
  DesktopUpdateActionResult,
  DesktopUpdateState,
  EnvironmentId,
  OrchestrationV2ThreadShell,
} from "@infinitus/contracts";
import { PRODUCT_NAME } from "@infinitus/shared/productName";

export type DesktopUpdateButtonAction = "download" | "install" | "none";

const DEFAULT_DESKTOP_RELEASE_REPOSITORY = "pingdotgg/t3code";
const GITHUB_REPOSITORY_SEGMENT = /^[A-Za-z0-9._-]+$/u;

function isValidRepositorySegment(value: string | undefined): value is string {
  return (
    value !== undefined && value !== "." && value !== ".." && GITHUB_REPOSITORY_SEGMENT.test(value)
  );
}

function desktopReleaseRepositoryUrl(repository: string | undefined): string {
  const configuredRepository = repository?.trim() ?? "";
  const [owner, name, ...extra] = configuredRepository.split("/");
  const releaseRepository =
    isValidRepositorySegment(owner) && isValidRepositorySegment(name) && extra.length === 0
      ? configuredRepository
      : DEFAULT_DESKTOP_RELEASE_REPOSITORY;
  return `https://github.com/${releaseRepository}/releases`;
}

/**
 * The main process fills `downloadedVersion` from the updater's `update-downloaded`
 * event, which is dispatched on its own fiber. A download RPC can therefore resolve
 * before that write lands, so fall back to the version the download was started for.
 */
export function getDesktopUpdateDownloadedVersion(state: DesktopUpdateState): string | null {
  return state.downloadedVersion ?? state.availableVersion;
}

export function getDesktopUpdateReleaseUrl(
  version: string | null,
  repository: string | undefined = import.meta.env.T3CODE_DESKTOP_UPDATE_REPOSITORY,
): string | null {
  const normalizedVersion = version?.trim();
  if (!normalizedVersion) return null;
  return `${desktopReleaseRepositoryUrl(repository)}/tag/v${encodeURIComponent(normalizedVersion)}`;
}

export function getDesktopUpdateReleaseHistoryUrl(
  repository: string | undefined = import.meta.env.T3CODE_DESKTOP_UPDATE_REPOSITORY,
): string {
  return desktopReleaseRepositoryUrl(repository);
}

export function resolveDesktopUpdateButtonAction(
  state: DesktopUpdateState,
): DesktopUpdateButtonAction {
  if (
    state.downloadedVersion &&
    (state.status === "downloaded" ||
      (state.status === "error" &&
        (state.errorContext === null || state.errorContext === "install")))
  ) {
    return "install";
  }
  if (state.status === "available") {
    return "download";
  }
  if (state.status === "error") {
    if (state.errorContext === "download" && state.availableVersion) {
      return "download";
    }
  }
  return "none";
}

export function shouldShowArm64IntelBuildWarning(state: DesktopUpdateState | null): boolean {
  return state?.hostArch === "arm64" && state.appArch === "x64";
}

export function isDesktopUpdateButtonDisabled(state: DesktopUpdateState | null): boolean {
  return state?.status === "downloading";
}

export function getArm64IntelBuildWarningDescription(state: DesktopUpdateState): string {
  if (!shouldShowArm64IntelBuildWarning(state)) {
    return "This install is using the correct architecture.";
  }

  const action = resolveDesktopUpdateButtonAction(state);
  if (action === "download") {
    return `This Mac has Apple Silicon, but ${PRODUCT_NAME} is still running the Intel build under Rosetta. Download the available update to switch to the native Apple Silicon build.`;
  }
  if (action === "install") {
    return `This Mac has Apple Silicon, but ${PRODUCT_NAME} is still running the Intel build under Rosetta. Restart to install the downloaded Apple Silicon build.`;
  }
  return `This Mac has Apple Silicon, but ${PRODUCT_NAME} is still running the Intel build under Rosetta. The next app update will replace it with the native Apple Silicon build.`;
}

export function getDesktopUpdateButtonTooltip(state: DesktopUpdateState): string {
  if (
    state.notAppliedVersion !== undefined &&
    (state.status === "available" || state.status === "downloaded") &&
    getDesktopUpdateDownloadedVersion(state) === state.notAppliedVersion
  ) {
    return `Update ${state.notAppliedVersion} did not apply. Click to retry.`;
  }
  if (state.status === "available") {
    return `Update ${state.availableVersion ?? "available"} ready to download`;
  }
  if (state.status === "downloading") {
    const progress =
      typeof state.downloadPercent === "number" ? ` (${Math.floor(state.downloadPercent)}%)` : "";
    return `Downloading update${progress}`;
  }
  if (state.status === "downloaded") {
    return `Update ${state.downloadedVersion ?? state.availableVersion ?? "ready"} downloaded. Click to restart and install.`;
  }
  if (state.status === "error") {
    if (state.errorContext === "download" && state.availableVersion) {
      return `Download failed for ${state.availableVersion}. Click to retry.`;
    }
    if (state.errorContext === "install" && state.downloadedVersion) {
      return `Install failed for ${state.downloadedVersion}. Click to retry.`;
    }
    if (state.downloadedVersion) {
      return `Update ${state.downloadedVersion} downloaded. Click to restart and install.`;
    }
    return state.message ?? "Update failed";
  }
  return "Up to date";
}

export function getDesktopUpdateInstallConfirmationMessage(
  state: Pick<DesktopUpdateState, "availableVersion" | "downloadedVersion">,
): string {
  const version = state.downloadedVersion ?? state.availableVersion;
  return `Install update${version ? ` ${version}` : ""} and restart ${PRODUCT_NAME}?\n\nAny running tasks will be interrupted. Make sure you're ready before continuing.`;
}

export function getDesktopUpdateActionError(result: DesktopUpdateActionResult): string | null {
  if (!result.accepted || result.completed) return null;
  if (typeof result.state.message !== "string") return null;
  const message = result.state.message.trim();
  return message.length > 0 ? message : null;
}

export function shouldToastDesktopUpdateActionResult(result: DesktopUpdateActionResult): boolean {
  return getDesktopUpdateActionError(result) !== null;
}

export function canCheckForUpdate(state: DesktopUpdateState | null): boolean {
  if (!state || !state.enabled) return false;
  return (
    state.status !== "checking" && state.status !== "downloading" && state.status !== "disabled"
  );
}

<<<<<<< HEAD
// ---------------------------------------------------------------------------
// #829: installing the desktop update quits the app, and with it every local
// backend's running turns. The count below is read from the same thread
// shells the sidebar shows — never from process heuristics.

/** The shell fields the count reads (`EnvironmentThreadShell` fits). */
export interface DesktopUpdateThreadShell {
  readonly environmentId: EnvironmentId;
  readonly source: Pick<OrchestrationV2ThreadShell, "activityRunStatus">;
}

/** Threads whose run is live on local backends (primary or desktop-local):
    the shell's `activityRunStatus`, the server's own definition
    (`InfinitusRunningTurns`); a run waiting on an approval counts, it dies
    with the process too. */
export function countRunningLocalTurns(
  shells: ReadonlyArray<DesktopUpdateThreadShell>,
  isLocalEnvironment: (environmentId: EnvironmentId) => boolean,
): number {
  let count = 0;
  for (const shell of shells) {
    if (shell.source.activityRunStatus != null && isLocalEnvironment(shell.environmentId)) {
      count += 1;
    }
  }
  return count;
}

function runningThreadsPhrase(count: number): string {
  return count === 1 ? "1 running thread" : `${count} running threads`;
}

/** The dialog an install click gets instead of the plain confirm while
    turns run (#829): the old confirm's title, then what would be cut off;
    `null` is an unknown count (some backend's shells have not loaded),
    which offers only "Install now". */
export function getDesktopUpdateRunningTurnsDialog(
  count: number | null,
  state: Pick<DesktopUpdateState, "availableVersion" | "downloadedVersion">,
): {
  readonly title: string;
  readonly description: string;
} {
  if (count === null) {
    return {
      title: "Could not confirm no threads are running",
      description: `Some backends have not loaded yet. Installing now may interrupt a running thread.`,
    };
  }
  const version = state.downloadedVersion ?? state.availableVersion;
  const them = count === 1 ? "it" : "them";
  return {
    title: `Install update${version ? ` ${version}` : ""} and restart ${PRODUCT_NAME}?`,
    description: `${runningThreadsPhrase(count)} would be interrupted. Install when ${count === 1 ? "it finishes" : "they finish"}, or install now and cut ${them} off.`,
  };
}

/** The dialog a click on the armed button gets: the wait can be kept, cancelled or skipped. */
export function getDesktopUpdateArmedDialog(count: number): {
  readonly title: string;
  readonly description: string;
} {
  return {
    title: `Installing when ${runningThreadsPhrase(count)} finish${count === 1 ? "es" : ""}`,
    description: `The update installs on its own once every running thread on this Mac has finished.`,
  };
}

/** The update button while "Install when they finish" is armed. */
export function getDesktopUpdateArmedTooltip(count: number): string {
  return `Installs when ${runningThreadsPhrase(count)} finish${count === 1 ? "es" : ""}. Click to cancel.`;
}

/**
 * What the armed "Install when they finish" wait does on a state change
 * (#829, #1037). The wait outlives a poll that reads "checking" and a newer
 * release that supersedes the downloaded one (the fork channel downloads it on
 * its own); it is dropped only when nothing is left to install at all.
 */
export function resolveInstallWhenIdleStep(
  state: DesktopUpdateState | null,
  action: DesktopUpdateButtonAction,
  runningLocalTurns: number | null,
): "install" | "wait" | "disarm" {
  if (!state || (state.downloadedVersion === null && state.availableVersion === null)) {
    return "disarm";
  }
  return action === "install" && runningLocalTurns === 0 ? "install" : "wait";
=======
export function getDesktopUpdateDisabledReason(
  state: Pick<DesktopUpdateState, "enabled" | "status" | "message"> | null,
): string | null {
  if (!state || (state.enabled && state.status !== "disabled")) return null;
  return state.message?.trim() || "Automatic updates are not available in this build.";
}

export function getDesktopUpdateIdleTooltip(
  state: Pick<DesktopUpdateState, "enabled" | "status" | "message"> | null,
) {
  const disabledReason = getDesktopUpdateDisabledReason(state);
  return disabledReason
    ? { title: "Updates unavailable", detail: disabledReason }
    : { title: "Check for updates", detail: null };
>>>>>>> upstream-sync-8866e8fdc-upstream-renamed
}
