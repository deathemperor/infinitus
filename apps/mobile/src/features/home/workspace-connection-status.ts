import type { WorkspaceState } from "../../state/workspaceModel";

export interface WorkspaceConnectionStatusPresentation {
  readonly label: string;
<<<<<<< HEAD
  /** True while the label describes work in flight (connecting/syncing) — render a spinner. False when the label says we cannot connect — render a wifi-slash icon. */
=======
>>>>>>> upstream-sync-43879d970-upstream-renamed
  readonly showsProgress: boolean;
}

function shouldShowWorkspaceConnectionStatus(state: WorkspaceState): boolean {
  if (state.networkStatus === "offline") return true;
  if (state.hasReadyEnvironment) return state.hasSyncingConnectedEnvironment;
  return (
    state.connectionError !== null ||
    state.hasConnectingEnvironment ||
    state.hasPendingShellSnapshot ||
    (state.hasLoadedShellSnapshot && !state.hasReadyEnvironment)
  );
}

<<<<<<< HEAD
/**
 * Label and icon are decided together so they can never disagree: a retry in
 * flight reads "Reconnecting" beside a spinner, and the wifi-slash icon is
 * reserved for the states whose label says we cannot connect. A recorded
 * failure does not stop the spinner — the supervisor is still retrying.
 */
function workspaceConnectionStatus(state: WorkspaceState): WorkspaceConnectionStatusPresentation {
  if (state.networkStatus === "offline") {
    return { label: "You are offline", showsProgress: false };
=======
function workspaceConnectionStatusLabel(state: WorkspaceState): string {
  if (state.networkStatus === "offline") return "You are offline";
  if (state.hasReadyEnvironment && state.hasSyncingConnectedEnvironment) {
    return state.hasLoadedShellSnapshot ? "Syncing threads..." : "Loading threads...";
>>>>>>> upstream-sync-43879d970-upstream-renamed
  }
  if (state.connectingEnvironments.length === 1) {
    return {
      label: `Reconnecting to ${state.connectingEnvironments[0]!.environmentLabel}`,
      showsProgress: true,
    };
  }
  if (state.connectingEnvironments.length > 1) {
    return {
      label: `Reconnecting ${state.connectingEnvironments.length} environments`,
      showsProgress: true,
    };
  }
  if (state.connectionError !== null) {
    return { label: state.connectionError, showsProgress: false };
  }
  if (state.hasPendingShellSnapshot) {
    return {
      label: state.hasLoadedShellSnapshot ? "Syncing threads..." : "Loading threads...",
      showsProgress: true,
    };
  }
  return { label: "Not connected", showsProgress: false };
}

export function workspaceConnectionStatusPresentation(
  state: WorkspaceState,
): WorkspaceConnectionStatusPresentation | null {
  if (!shouldShowWorkspaceConnectionStatus(state)) return null;
<<<<<<< HEAD
  return workspaceConnectionStatus(state);
=======
  return {
    label: workspaceConnectionStatusLabel(state),
    showsProgress:
      state.networkStatus !== "offline" &&
      (state.hasReadyEnvironment || state.connectionError === null) &&
      (state.connectingEnvironments.length > 0 || state.hasPendingShellSnapshot),
  };
>>>>>>> upstream-sync-43879d970-upstream-renamed
}
