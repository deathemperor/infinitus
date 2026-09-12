import type {
  DesktopUpdateActionResult,
  DesktopUpdateState,
  EnvironmentId,
  TurnId,
} from "@t3tools/contracts";
import { PRODUCT_NAME } from "@t3tools/shared/productName";

export type DesktopUpdateButtonAction = "download" | "install" | "none";

const DESKTOP_RELEASE_HISTORY_URL = "https://github.com/pingdotgg/t3code/releases";
const DESKTOP_RELEASE_TAG_URL = `${DESKTOP_RELEASE_HISTORY_URL}/tag`;

/**
 * The main process fills `downloadedVersion` from the updater's `update-downloaded`
 * event, which is dispatched on its own fiber. A download RPC can therefore resolve
 * before that write lands, so fall back to the version the download was started for.
 */
export function getDesktopUpdateDownloadedVersion(state: DesktopUpdateState): string | null {
  return state.downloadedVersion ?? state.availableVersion;
}

/** Release notes for an exact downloaded build; nightly suffixes are part of the tag. */
export function getDesktopUpdateReleaseUrl(version: string | null): string | null {
  const normalizedVersion = version?.trim();
  if (!normalizedVersion) return null;
  return `${DESKTOP_RELEASE_TAG_URL}/v${encodeURIComponent(normalizedVersion)}`;
}

export function getDesktopUpdateReleaseHistoryUrl(): string {
  return DESKTOP_RELEASE_HISTORY_URL;
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

// ---------------------------------------------------------------------------
// #829: installing the desktop update quits the app, and with it every local
// backend's running turns. The count below is read from the same thread
// shells the sidebar shows — never from process heuristics.

/** The shell fields the count reads (`EnvironmentThreadShell` fits). */
export interface DesktopUpdateThreadShell {
  readonly environmentId: EnvironmentId;
  readonly session: { readonly activeTurnId: TurnId | null } | null;
}

/** Turns with an active id on local backends (primary or desktop-local);
    a turn waiting on an approval counts, it dies with the process too. */
export function countRunningLocalTurns(
  shells: ReadonlyArray<DesktopUpdateThreadShell>,
  isLocalEnvironment: (environmentId: EnvironmentId) => boolean,
): number {
  let count = 0;
  for (const shell of shells) {
    if (shell.session?.activeTurnId != null && isLocalEnvironment(shell.environmentId)) count += 1;
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
